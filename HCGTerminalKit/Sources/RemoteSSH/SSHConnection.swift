import Crypto
import Diagnostics
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import TerminalCore
import TerminalSecurity

/// Credentials resolved for one connection attempt. Never persisted by this module.
public enum SSHAuthentication: Sendable {
    case password(String)
    /// An Ed25519 or ECDSA private key (raw bytes, so the value is `Sendable` everywhere).
    case key(SSHPrivateKey)
    /// Try the key first, then the password.
    case keyThenPassword(SSHPrivateKey, password: String)

    public static func ed25519(_ key: Curve25519.Signing.PrivateKey) -> SSHAuthentication {
        .key(.ed25519(key.rawRepresentation))
    }
}

extension SSHPrivateKey {
    /// The SwiftNIO SSH key used to sign the authentication request.
    func nioKey() throws -> NIOSSHPrivateKey {
        switch self {
        case .ed25519(let raw): NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: raw))
        case .p256(let raw): NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: raw))
        case .p384(let raw): NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: raw))
        case .p521(let raw): NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: raw))
        }
    }
}

public enum SSHConnectionError: Error, LocalizedError, Equatable {
    case hostNotFound(host: String)
    case connectionRefused(host: String, port: Int)
    case hostUnreachable(host: String, detail: String)
    case connectionFailed(host: String, detail: String)
    case hostKeyNotTrusted(fingerprint: String)
    case hostKeyChanged(expected: String, presented: String)
    case authenticationFailed
    case timedOut
    case disconnected
    case channelRejected(String)

    public var errorDescription: String? {
        switch self {
        case .hostNotFound(let host):
            "Could not find “\(host)”. Check the hostname; for a Mac on the same network try its .local name (System Settings → General → Sharing) or its IP address."
        case .connectionRefused(let host, let port):
            "\(host) refused the connection on port \(port). Is SSH running there? On a Mac: System Settings → General → Sharing → Remote Login."
        case .hostUnreachable(let host, let detail):
            "\(host) cannot be reached from this device (\(detail)). Check that both are on the same network or VPN, and that HCG Terminal is allowed under Settings → Privacy & Security → Local Network."
        case .connectionFailed(let host, let detail): "Could not connect to \(host): \(detail)."
        case .hostKeyNotTrusted(let fingerprint): "The host key \(fingerprint) was not trusted, so no connection was made."
        case .hostKeyChanged(let expected, let presented):
            "The host key changed (expected \(expected), got \(presented)). The connection was refused. If the change is expected, remove the old key and verify the new one."
        case .authenticationFailed: "The server rejected the sign-in. Check the username, the password, or that this device's public key is in ~/.ssh/authorized_keys on the host."
        case .timedOut: "The server did not answer in time. Check the address and port, and that the host is awake."
        case .disconnected: "The connection was closed before the command finished."
        case .channelRejected(let what): "The server refused to open \(what)."
        }
    }

    /// Short category for the interface.
    public var category: String {
        switch self {
        case .hostNotFound: "Host not found (DNS)"
        case .connectionRefused: "Connection refused"
        case .hostUnreachable: "Host unreachable"
        case .connectionFailed: "Connection failed"
        case .hostKeyNotTrusted: "Host key not trusted"
        case .hostKeyChanged: "Host key changed"
        case .authenticationFailed: "Authentication failed"
        case .timedOut: "Timed out"
        case .disconnected: "Disconnected"
        case .channelRejected: "Request refused"
        }
    }

    /// Maps transport errors (DNS, TCP) to a specific case.
    public static func classify(_ error: Error, host: String, port: Int) -> SSHConnectionError {
        if let known = error as? SSHConnectionError { return known }
        if let connection = error as? NIOConnectionError {
            if connection.connectionErrors.isEmpty, connection.dnsAError != nil || connection.dnsAAAAError != nil {
                return .hostNotFound(host: host)
            }
            let codes = connection.connectionErrors.compactMap { ($0.error as? IOError)?.errnoCode }
            if codes.contains(ECONNREFUSED) { return .connectionRefused(host: host, port: port) }
            if let code = codes.first(where: { [EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN].contains($0) }) {
                return .hostUnreachable(host: host, detail: String(cString: strerror(code)))
            }
            if codes.contains(ETIMEDOUT) { return .timedOut }
            if connection.connectionErrors.contains(where: { if case ChannelError.connectTimeout = $0.error { true } else { false } }) {
                return .timedOut
            }
            return .connectionFailed(host: host, detail: connection.connectionErrors.first.map { "\($0.error)" } ?? "\(connection)")
        }
        if case ChannelError.connectTimeout = error { return .timedOut }
        if let io = error as? IOError {
            switch io.errnoCode {
            case ECONNREFUSED: return .connectionRefused(host: host, port: port)
            case EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN: return .hostUnreachable(host: host, detail: String(cString: strerror(io.errnoCode)))
            case ETIMEDOUT: return .timedOut
            default: break
            }
        }
        return .connectionFailed(host: host, detail: "\(error)")
    }
}

/// How unknown host keys are handled: looked up in the known-hosts store; unknown keys need
/// explicit approval from the user; changed keys are always refused.
public struct HostKeyPolicy: Sendable {
    public typealias Approver = @Sendable (_ host: String, _ port: Int, _ key: PresentedHostKey) async -> Bool

    public let knownHosts: KnownHostsStore
    public let approveUnknownKey: Approver

    public init(knownHosts: KnownHostsStore, approveUnknownKey: @escaping Approver) {
        self.knownHosts = knownHosts
        self.approveUnknownKey = approveUnknownKey
    }

    func evaluate(host: String, port: Int, key: PresentedHostKey) async -> Result<Void, SSHConnectionError> {
        switch await knownHosts.verdict(host: host, port: port, key: key) {
        case .trusted:
            return .success(())
        case .unknown(let presented):
            guard await approveUnknownKey(host, port, presented) else {
                return .failure(.hostKeyNotTrusted(fingerprint: presented.fingerprint))
            }
            try? await knownHosts.trust(host: host, port: port, key: presented)
            return .success(())
        case .mismatch(let expected, let presented):
            return .failure(.hostKeyChanged(expected: expected, presented: presented.fingerprint))
        }
    }
}

/// Records why establishment failed, so the caller gets a precise error.
final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var error: SSHConnectionError?

    func record(_ error: SSHConnectionError) {
        lock.lock(); defer { lock.unlock() }
        if self.error == nil { self.error = error }
    }

    var recorded: SSHConnectionError? {
        lock.lock(); defer { lock.unlock() }
        return error
    }
}

final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    let host: String
    let port: Int
    let policy: HostKeyPolicy
    let failures: FailureRecorder

    init(host: String, port: Int, policy: HostKeyPolicy, failures: FailureRecorder) {
        self.host = host
        self.port = port
        self.policy = policy
        self.failures = failures
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let presented = PresentedHostKey(openSSHLine: String(openSSHPublicKey: hostKey)) else {
            failures.record(.hostKeyNotTrusted(fingerprint: "unreadable key"))
            validationCompletePromise.fail(SSHConnectionError.hostKeyNotTrusted(fingerprint: "unreadable key"))
            return
        }
        let policy = self.policy, host = self.host, port = self.port, failures = self.failures
        Task {
            switch await policy.evaluate(host: host, port: port, key: presented) {
            case .success:
                validationCompletePromise.succeed(())
            case .failure(let error):
                failures.record(error)
                validationCompletePromise.fail(error)
            }
        }
    }
}

final class UserAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let authentication: SSHAuthentication
    let failures: FailureRecorder
    private var triedKey = false
    private var triedPassword = false

    init(username: String, authentication: SSHAuthentication, failures: FailureRecorder) {
        self.username = username
        self.authentication = authentication
        self.failures = failures
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        var key: NIOSSHPrivateKey?
        var password: String?
        switch authentication {
        case .key(let privateKey): key = try? privateKey.nioKey()
        case .password(let p): password = p
        case .keyThenPassword(let privateKey, let p): key = try? privateKey.nioKey(); password = p
        }
        if let key, !triedKey, availableMethods.contains(.publicKey) {
            triedKey = true
            let offer = NIOSSHUserAuthenticationOffer.Offer.PrivateKey(privateKey: key)
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(offer)))
            return
        }
        if let password, !triedPassword, availableMethods.contains(.password) {
            triedPassword = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .password(.init(password: password))))
            return
        }
        failures.record(.authenticationFailed)
        nextChallengePromise.fail(SSHConnectionError.authenticationFailed)
    }
}

/// Completes `promise` once user authentication succeeds, or fails it when the connection
/// errors or closes first.
final class AuthenticationWatcher: ChannelInboundHandler {
    typealias InboundIn = Any

    private var promise: EventLoopPromise<Void>?
    private let failures: FailureRecorder

    init(promise: EventLoopPromise<Void>, failures: FailureRecorder) {
        self.promise = promise
        self.failures = failures
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            promise?.succeed(())
            promise = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise?.fail(failures.recorded ?? (error as? SSHConnectionError) ?? .authenticationFailed)
        promise = nil
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise?.fail(failures.recorded ?? .disconnected)
        promise = nil
        context.fireChannelInactive()
    }
}

/// One authenticated SSH connection. Sessions and commands are multiplexed over it as
/// separate channels, so closing one session never affects another.
///
/// This type knows nothing about local execution modes: remote work is independent of them.
public final class SSHConnection: RemoteCommandExecuting, @unchecked Sendable {
    public let endpoint: RemoteEndpoint
    let channel: Channel
    /// Switches checked again before every command or session on this connection, so turning
    /// SSH off also stops an already open connection from being used.
    let requiredAccess: [AccessControl]
    let access: AccessPolicy

    init(endpoint: RemoteEndpoint, channel: Channel, requiredAccess: [AccessControl] = [.remoteSSH], access: AccessPolicy = .shared) {
        self.endpoint = endpoint
        self.channel = channel
        self.requiredAccess = requiredAccess
        self.access = access
    }

    public var isActive: Bool { channel.isActive }

    public static func connect(
        endpoint: RemoteEndpoint,
        authentication: SSHAuthentication,
        hostKeyPolicy: HostKeyPolicy,
        timeout: TimeAmount = .seconds(20),
        requiredAccess: [AccessControl] = [.remoteSSH],
        access: AccessPolicy = .shared
    ) async throws -> SSHConnection {
        // Refused before any network activity when the user turned SSH off.
        try access.requireAll(requiredAccess)
        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
        let authenticated = eventLoop.makePromise(of: Void.self)
        let failures = FailureRecorder()

        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: UserAuthDelegate(username: endpoint.username, authentication: authentication, failures: failures),
                            serverAuthDelegate: HostKeyDelegate(host: endpoint.hostname, port: endpoint.port, policy: hostKeyPolicy, failures: failures)
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(AuthenticationWatcher(promise: authenticated, failures: failures))
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.hostname, port: endpoint.port).get()
        } catch {
            let classified = SSHConnectionError.classify(error, host: endpoint.hostname, port: endpoint.port)
            authenticated.fail(classified)
            await DiagnosticLog.shared.record(.warning, "ssh", "Connection failed", metadata: ["host": endpoint.address, "category": classified.category])
            throw classified
        }
        let timeoutTask = eventLoop.scheduleTask(in: timeout) {
            authenticated.fail(SSHConnectionError.timedOut)
        }
        do {
            try await authenticated.futureResult.get()
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            channel.close(promise: nil)
            let classified = SSHConnectionError.classify(error, host: endpoint.hostname, port: endpoint.port)
            await DiagnosticLog.shared.record(.warning, "ssh", "Connection failed", metadata: ["host": endpoint.address, "category": classified.category])
            throw classified
        }
        await DiagnosticLog.shared.record(.info, "ssh", "Connected", metadata: ["host": endpoint.address])
        return SSHConnection(endpoint: endpoint, channel: channel, requiredAccess: requiredAccess, access: access)
    }

    /// Opens a child channel on the event loop and installs `makeHandler()` on it.
    func openChildChannel(_ install: @escaping @Sendable (Channel) throws -> Void) async throws -> Channel {
        let channel = self.channel
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        channel.eventLoop.execute {
            do {
                let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(promise, channelType: .session) { child, type in
                    guard type == .session else {
                        return child.eventLoop.makeFailedFuture(SSHConnectionError.channelRejected("a session"))
                    }
                    return child.eventLoop.makeCompletedFuture { try install(child) }
                }
            } catch {
                promise.fail(error)
            }
        }
        return try await promise.futureResult.get()
    }

    // MARK: RemoteCommandExecuting

    public func stream(_ command: String) -> AsyncThrowingStream<RemoteExecEvent, Error> {
        AsyncThrowingStream { continuation in
            do { try self.access.requireAll(self.requiredAccess) } catch {
                continuation.finish(throwing: error)
                return
            }
            let task = Task {
                do {
                    let child = try await self.openChildChannel { child in
                        try child.pipeline.syncOperations.addHandler(ExecChannelHandler(command: command, continuation: continuation))
                    }
                    continuation.onTermination = { termination in
                        if case .cancelled = termination { child.close(promise: nil) }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Interactive sessions

    /// Opens an interactive PTY session. `command == nil` starts the login shell; otherwise the
    /// command runs with a PTY (used for Claude Code and other full-screen tools).
    /// `target` is normally `.remote(endpoint)`; loopback services pass `.local(.unleashed)`.
    public func openSession(
        size: TerminalSize,
        command: String? = nil,
        target: ExecutionTarget? = nil,
        backend: SessionBackend? = nil
    ) async throws -> SSHShellSession {
        try access.requireAll(requiredAccess)
        let session = SSHShellSession(
            connection: self,
            target: target ?? .remote(endpoint),
            backend: backend ?? (command.map { .sshCommand($0) } ?? .sshShell),
            command: command
        )
        try await session.start(size: size)
        return session
    }

    public func close() async {
        try? await channel.close().get()
        await DiagnosticLog.shared.record(.info, "ssh", "Disconnected", metadata: ["host": endpoint.address])
    }
}

/// Runs one command without a PTY and streams its output.
final class ExecChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let continuation: AsyncThrowingStream<RemoteExecEvent, Error>.Continuation
    private var exitStatus: Int32?
    private var finished = false

    init(command: String, continuation: AsyncThrowingStream<RemoteExecEvent, Error>.Continuation) {
        self.command = command
        self.continuation = continuation
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(request, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        let bytes = Data(buffer.readableBytesView)
        switch message.type {
        case .channel: continuation.yield(.stdout(bytes))
        case .stdErr: continuation.yield(.stderr(bytes))
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = Int32(truncatingIfNeeded: status.exitStatus)
        case let signal as SSHChannelRequestEvent.ExitSignal:
            exitStatus = 128 + (SSHSignals.number(for: signal.signalName) ?? 0)
        case is ChannelFailureEvent:
            finish(error: SSHConnectionError.channelRejected("the command"))
            context.close(promise: nil)
        case ChannelEvent.inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(error: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(error: nil)
        context.fireChannelInactive()
    }

    private func finish(error: Error?) {
        guard !finished else { return }
        finished = true
        if let error {
            continuation.finish(throwing: error)
        } else if let exitStatus {
            continuation.yield(.exit(status: exitStatus))
            continuation.finish()
        } else {
            // The channel closed without an exit status: the connection was lost (or the
            // server killed the session). Never report an invented status.
            continuation.finish(throwing: SSHConnectionError.disconnected)
        }
    }
}

enum SSHSignals {
    static func number(for name: String) -> Int32? {
        ["HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "ABRT": 6, "FPE": 8, "KILL": 9, "SEGV": 11, "PIPE": 13, "ALRM": 14, "TERM": 15, "USR1": 10, "USR2": 12][name]
    }
}
