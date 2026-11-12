import Foundation
import RemoteSSH
import TerminalCore
import TerminalSecurity
import XCTest

/// Runs without a server: with SSH turned off, nothing touches the network.
final class SSHAccessTests: XCTestCase {
    func testConnectIsRefusedBeforeAnyNetworkActivity() async {
        let access = AccessPolicy.inMemory()
        access.set(.remoteSSH, enabled: false)
        let asked = LockedFlagBox()
        // 192.0.2.1 is TEST-NET-1: a real connect would hang until the timeout.
        let endpoint = RemoteEndpoint(hostID: UUID(), displayName: "Test", hostname: "192.0.2.1", port: 22, username: "nobody")
        let started = Date()
        do {
            _ = try await SSHConnection.connect(
                endpoint: endpoint, authentication: .password("x"),
                hostKeyPolicy: HostKeyPolicy(knownHosts: KnownHostsStore(fileURL: nil)) { _, _, _ in asked.set(); return true },
                access: access
            )
            XCTFail("must be refused")
        } catch let denied as AccessDenied {
            XCTAssertEqual(denied.control, .remoteSSH)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "refused immediately, no connection attempt")
        XCTAssertFalse(asked.value, "no host key was ever presented")
    }

    func testLoopbackServiceUsesTheShellSwitch() async {
        let access = AccessPolicy.inMemory()
        access.set(.localShell, enabled: false)
        let endpoint = RemoteEndpoint(hostID: UUID(), displayName: "This device", hostname: "127.0.0.1", port: 1, username: "mobile")
        do {
            _ = try await SSHConnection.connect(
                endpoint: endpoint, authentication: .password("x"),
                hostKeyPolicy: HostKeyPolicy(knownHosts: KnownHostsStore(fileURL: nil)) { _, _, _ in false },
                requiredAccess: [.localShell], access: access
            )
            XCTFail("must be refused")
        } catch let denied as AccessDenied {
            XCTAssertEqual(denied.control, .localShell)
        } catch {
            XCTFail("\(error)")
        }
    }
}

final class LockedFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
