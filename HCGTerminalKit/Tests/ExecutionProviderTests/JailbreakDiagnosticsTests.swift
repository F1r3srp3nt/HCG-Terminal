import Foundation
import TerminalCore
@testable import UnleashedExecutionProvider
import XCTest

final class JailbreakDiagnosticsTests: XCTestCase {
    /// A minimal arm64 Mach-O with LC_CODE_SIGNATURE → SuperBlob { CodeDirectory, Entitlements, [CMS] }.
    static func machO(entitlements: [String: Bool], certificate: Bool = false, fat: Bool = false) -> [UInt8] {
        func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
        let xml = try! PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        let entBlob = be(0xFADE_7171) + be(UInt32(8 + xml.count)) + [UInt8](xml)
        let cdBlob = be(0xFADE_0C02) + be(12) + [0, 0, 0, 0]
        let cmsBlob = be(0xFADE_0B01) + be(certificate ? 16 : 8) + (certificate ? [1, 2, 3, 4, 5, 6, 7, 8] : [])
        var blobs: [(UInt32, [UInt8])] = [(0, cdBlob), (5, entBlob)]
        blobs.append((0x10000, cmsBlob))
        let headerSize = 12 + blobs.count * 8
        var index: [UInt8] = []
        var body: [UInt8] = []
        for (type, blob) in blobs {
            index += be(type) + be(UInt32(headerSize + body.count))
            body += blob
        }
        let superBlob = be(0xFADE_0CC0) + be(UInt32(headerSize + body.count)) + be(UInt32(blobs.count)) + index + body
        // mach_header_64 (32 bytes) + one LC_CODE_SIGNATURE (16 bytes), signature right after.
        let sigOffset: UInt32 = 32 + 16
        var thin = le(0xFEED_FACF) + le(0x0100_000C) + le(0) + le(2) + le(1) + le(16) + le(0) + le(0)
        thin += le(0x1D) + le(16) + le(sigOffset) + le(UInt32(superBlob.count))
        thin += superBlob
        guard fat else { return thin }
        // fat header with an x86_64 slice first (garbage) and the arm64 slice second.
        let x86 = [UInt8](repeating: 0, count: 64)
        let headerLen = 8 + 2 * 20
        let x86Offset = UInt32(headerLen), armOffset = UInt32(headerLen + x86.count)
        var out = be(0xCAFE_BABE) + be(2)
        out += be(0x0100_0007) + be(3) + be(x86Offset) + be(UInt32(x86.count)) + be(0)
        out += be(0x0100_000C) + be(0) + be(armOffset) + be(UInt32(thin.count)) + be(0)
        return out + x86 + thin
    }

    func testMachOSignatureParsing() {
        let ldid = MachOSignature.parse(Self.machO(entitlements: ["com.apple.private.security.no-sandbox": true]))
        XCTAssertEqual(ldid, MachOSignature.Info(signed: true, hasCertificateSignature: false, entitlements: ["com.apple.private.security.no-sandbox": "true"]))
        let apple = MachOSignature.parse(Self.machO(entitlements: [:], certificate: true, fat: true))
        XCTAssertEqual(apple?.hasCertificateSignature, true)
        XCTAssertEqual(apple?.entitlements, [:])
        XCTAssertNil(MachOSignature.parse(Array("not a binary".utf8)))
    }

    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jbdiag-\(UUID().uuidString.prefix(6))")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ text: String = "", executable: Bool = false, age days: Double? = nil) throws {
        let url = root.appendingPathComponent(String(path.dropFirst()))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        if let days { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86400)], ofItemAtPath: url.path) }
    }

    func makeDevice() throws -> JailbreakDiagnostics.Input {
        let jb = "/private/preboot/ABC/jb-xyz/procursus"
        let app = jb + "/Applications/HCGTerminalUnleashed.app"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("var"), withIntermediateDirectories: true)
        try write(jb + "/.procursus_strapped")
        try write(jb + "/.installed_dopamine")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("var/jb").path, withDestinationPath: root.path + jb)
        try write(jb + "/bin/sh", executable: true)
        try write(jb + "/usr/bin/dpkg", executable: true)
        try write(jb + "/usr/bin/uicache", executable: true)
        try write(app + "/hcg-pty-helper", executable: true)
        let binary = Self.machO(entitlements: ["com.apple.private.security.no-sandbox": true])
        let exe = root.appendingPathComponent(String((app + "/HCGTerminalUnleashed").dropFirst()))
        try Data(binary).write(to: exe)
        try write(jb + "/var/lib/dpkg/status", """
        Package: bash
        Status: install ok installed
        Version: 5.2

        Package: com.example.newtweak
        Status: install ok installed
        Depends: mobilesubstrate, preferenceloader

        Package: com.example.broken
        Status: install ok half-configured

        """)
        try write(jb + "/var/lib/dpkg/info/com.example.newtweak.list", "/var/jb/x", age: 1)
        try write(jb + "/etc/apt/sources.list.d/sileo.sources", "Types: deb\nURIs: https://repo.hakmicapitalgroup.com/repo/\nSuites: ./\n\nTypes: deb\nURIs: http://insecure.example/\nSuites: ./\n")
        try write(jb + "/var/lib/apt/lists/repo_Packages", "x", age: 45)
        try write("/var/mobile/Library/Logs/CrashReporter/SpringBoard-2026-11-20.ips", "{}", age: 2)
        return JailbreakDiagnostics.Input(
            fileSystemRoot: root.path, bundlePath: "/var/jb/Applications/HCGTerminalUnleashed.app",
            executablePath: app + "/HCGTerminalUnleashed", jailbreakRoot: jb, environmentVisible: true,
            loadedImages: ["/usr/lib/libSystem.B.dylib", jb + "/usr/lib/ellekit/libinjector.dylib"]
        )
    }

    func item(_ report: DiagnosticReport, _ section: String, _ id: String) -> DiagnosticReport.Item? {
        report.sections.first { $0.id == section }?.items.first { $0.id == id }
    }

    func testReportOnARootlessDevice() throws {
        let report = JailbreakDiagnostics(try makeDevice()).report()
        XCTAssertEqual(item(report, "installation", "location")?.status, .ok)
        XCTAssertEqual(item(report, "installation", "signature")?.status, .ok)
        XCTAssertEqual(item(report, "installation", "pty-helper")?.status, .ok)
        XCTAssertEqual(item(report, "bootstrap", "jbroot")?.status, .ok)
        XCTAssertTrue(item(report, "bootstrap", "jbroot")!.evidence.first!.contains("procursus"), "the /var/jb link target is shown")
        XCTAssertEqual(item(report, "bootstrap", "markers")?.detail, ".procursus_strapped, .installed_dopamine")
        XCTAssertEqual(item(report, "bootstrap", "tool-Shell")?.status, .ok)
        XCTAssertEqual(item(report, "bootstrap", "tool-apt")?.status, .info)
        XCTAssertEqual(item(report, "packages", "unhealthy")?.status, .problem)
        XCTAssertEqual(item(report, "packages", "unhealthy")?.evidence, ["com.example.broken: install ok half-configured"])
        XCTAssertEqual(item(report, "repositories", "hcg-repo")?.status, .ok)
        XCTAssertEqual(item(report, "repositories", "http")?.evidence, ["http://insecure.example/"])
        XCTAssertEqual(item(report, "repositories", "refresh")?.status, .warning)
        XCTAssertEqual(item(report, "safe-mode", "injection")?.evidence.count, 1)
        XCTAssertEqual(item(report, "safe-mode", "tweaks")?.status, .warning, "a tweak installed yesterday")
        XCTAssertEqual(item(report, "safe-mode", "springboard-crashes")?.status, .warning)
        XCTAssertFalse(report.sections.first { $0.id == "storage" }!.items.isEmpty)
        XCTAssertTrue(report.text.contains("[PROBLEM] Interrupted or broken installs"))
    }

    func testSandboxedSideloadIsReportedHonestly() throws {
        var input = try makeDevice()
        input.bundlePath = "/private/var/containers/Bundle/Application/UUID/HCGTerminalUnleashed.app"
        input.environmentVisible = false
        input.jailbreakRoot = "/var/jb-missing"
        let report = JailbreakDiagnostics(input).report()
        XCTAssertEqual(item(report, "installation", "location")?.status, .warning)
        XCTAssertEqual(item(report, "installation", "sandbox")?.status, .warning)
        XCTAssertEqual(item(report, "bootstrap", "jbroot")?.status, .unknown, "not visible is not the same as missing")
        XCTAssertEqual(item(report, "packages", "status")?.status, .unknown)
    }

    func testDiagnosticsNeverWrite() throws {
        let input = try makeDevice()
        func snapshot() throws -> [String: Date] {
            var out: [String: Date] = [:]
            for path in FileManager.default.subpaths(atPath: root.path) ?? [] {
                out[path] = (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path))[.modificationDate] as? Date
            }
            return out
        }
        let before = try snapshot()
        _ = JailbreakDiagnostics(input).report()
        XCTAssertEqual(try snapshot(), before)
    }
}
