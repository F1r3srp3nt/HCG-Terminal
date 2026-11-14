import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HCGDeviceLink
#if canImport(UIKit)
import UIKit
#endif

/// How this installation describes itself to HCG Server (display only on the server).
public struct LinkDeviceDescription: Sendable, Equatable {
    public var name: String
    public var platform: String
    /// `identifierForVendor` on iOS: groups installations on one device; never used for authorization.
    public var deviceId: String?

    public init(name: String, platform: String, deviceId: String?) {
        self.name = name
        self.platform = platform
        self.deviceId = deviceId
    }
}

/// Everything the Device Link controller needs from the platform. The app builds one with
/// `platformDefault`; tests inject memory stores and a fake transport.
public struct DeviceLinkEnvironment: Sendable {
    public var variant: TerminalLinkVariant
    public var appVersion: String
    /// Keychain (this device only) in the app: installation ID, key and HCG Connect tokens.
    public var secrets: any LinkSecretStore
    /// Where the (non-secret) pairing record is kept.
    public var pairingFile: PairingRecordFile
    public var connect: HCGConnectSetup
    /// A transport that trusts exactly the server key with this fingerprint; `nil` when the
    /// platform has none (Device Link then stays unavailable).
    public var makeTransport: @Sendable (_ serverFingerprint: String) -> (any LinkTransport)?
    /// HCG Connect token requests (`nil` = URLSession).
    public var connectSend: (@Sendable (URLRequest) async throws -> (Data, Int))?
    public var describeDevice: @MainActor @Sendable () -> LinkDeviceDescription
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async throws -> Void
    /// Whether to prefer a Secure Enclave key for the installation identity.
    public var preferSecureEnclave: Bool

    public init(
        variant: TerminalLinkVariant, appVersion: String, secrets: any LinkSecretStore, pairingFile: PairingRecordFile,
        connect: HCGConnectSetup, makeTransport: @escaping @Sendable (String) -> (any LinkTransport)?,
        connectSend: (@Sendable (URLRequest) async throws -> (Data, Int))? = nil,
        describeDevice: @escaping @MainActor @Sendable () -> LinkDeviceDescription,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) },
        preferSecureEnclave: Bool = true
    ) {
        self.variant = variant
        self.appVersion = appVersion
        self.secrets = secrets
        self.pairingFile = pairingFile
        self.connect = connect
        self.makeTransport = makeTransport
        self.connectSend = connectSend
        self.describeDevice = describeDevice
        self.now = now
        self.sleep = sleep
        self.preferSecureEnclave = preferSecureEnclave
    }

    /// Keychain service for this app's Device Link items. Derived from the bundle identifier, so
    /// the standard and Unleashed apps never share an installation identity or tokens.
    public static func keychainService(bundleIdentifier: String?) -> String {
        (bundleIdentifier ?? "com.hakmicapitalgroup.hcgterminal") + ".devicelink"
    }

    /// Where `hcg-connect.json` is looked for: Application Support first (a file placed there
    /// later by the owner), then the app bundle. HCG Terminal ships a file without a client ID.
    public static func connectCandidates(applicationSupport: URL?, bundle: Bundle) -> [URL] {
        var urls: [URL] = []
        if let applicationSupport { urls.append(applicationSupport.appendingPathComponent(HCGConnectSetup.fileName)) }
        if let bundled = bundle.url(forResource: "hcg-connect", withExtension: "json") { urls.append(bundled) }
        return urls
    }

    /// The app's environment: Keychain, pinned TLS transport and the bundle's configuration.
    /// `nil` on platforms without a Keychain and pinned transport (Linux), where Device Link is
    /// not offered.
    public static func platformDefault(variant: TerminalLinkVariant, appVersion: String, bundle: Bundle = .main) -> DeviceLinkEnvironment? {
        #if canImport(Security) && canImport(Darwin)
        let fileManager = FileManager.default
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("HCGTerminal", isDirectory: true)
        let folder = (support ?? fileManager.temporaryDirectory).appendingPathComponent("DeviceLink", isDirectory: true)
        return DeviceLinkEnvironment(
            variant: variant,
            appVersion: appVersion,
            secrets: KeychainSecretStore(service: keychainService(bundleIdentifier: bundle.bundleIdentifier)),
            pairingFile: PairingRecordFile(url: folder.appendingPathComponent("pairing.json")),
            connect: HCGConnectSetup.load(candidates: connectCandidates(applicationSupport: support, bundle: bundle)),
            makeTransport: { PinnedSessionTransport(fingerprint: $0) },
            describeDevice: { @MainActor in currentDevice() }
        )
        #else
        return nil
        #endif
    }

    @MainActor
    static func currentDevice() -> LinkDeviceDescription {
        #if canImport(UIKit)
        let device = UIDevice.current
        return LinkDeviceDescription(name: device.name, platform: "\(device.systemName) \(device.systemVersion)",
                                     deviceId: device.identifierForVendor?.uuidString.lowercased())
        #else
        let info = ProcessInfo.processInfo
        return LinkDeviceDescription(name: info.hostName, platform: info.operatingSystemVersionString, deviceId: nil)
        #endif
    }
}
