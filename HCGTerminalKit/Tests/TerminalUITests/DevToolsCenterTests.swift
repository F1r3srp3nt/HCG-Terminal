import ArtifactManager
import BuildOrchestrator
import DeveloperWorkspace
import Diagnostics
import FileWorkspace
import Foundation
import TerminalCore
import TerminalSecurity
@testable import TerminalUI
import XCTest

/// The whole phone-side flow through the app model against real OpenSSH (127.0.0.1:2222):
/// Doctor → build job → live console → artifact download with checksum.
@MainActor
final class DevToolsCenterTests: XCTestCase {
    func testDoctorBuildConsoleAndDownloadThroughTheAppModel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HCG_SSH_TEST"] == "1", "set HCG_SSH_TEST=1 with Scripts/start-test-sshd.sh running")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hcg-devtools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "hcg-dt-\(UUID().uuidString)"))
        let workspace = try FileWorkspace(rootURL: root.appendingPathComponent("ws"))
        let credentials = InMemoryCredentialStore()
        let deps = AppDependencies.standard(
            workspace: workspace, supportDirectory: root.appendingPathComponent("support"),
            credentials: credentials, preferences: ModePreferenceStore(defaults: defaults),
            access: .inMemory(), appearance: AppearanceStore(defaults: defaults)
        )
        let app = TerminalAppModel(dependencies: deps)
        let host = HostProfile(name: "Test sshd", hostname: "127.0.0.1", port: 2222, username: "hcgtest", auth: .password)
        await app.saveHost(host, password: "hcg-test-pass")
        let line = try String(contentsOfFile: "/tmp/hcg-test-sshd/host_ed25519.pub", encoding: .utf8)
        try await deps.knownHosts.trust(host: "127.0.0.1", port: 2222, key: try XCTUnwrap(PresentedHostKey(openSSHLine: line)))

        // A Theos-shaped project whose "make" is a script writing a .deb.
        let folder = "devtools-\(UUID().uuidString.prefix(6))"
        let connection = try await app.connection(for: host)
        _ = try await connection.run("""
        mkdir -p ~/\(folder) && cd ~/\(folder) && printf 'TARGET := iphone:clang:latest:15.0\\ninclude $(THEOS)/makefiles/common.mk\\n' > Makefile && printf 'Package: com.example.t\\n' > control && \
        printf '#!/bin/sh\\necho "using password hcg-test-pass"\\nmkdir -p packages\\nprintf deb > packages/com.example.t_1.0_iphoneos-arm64.deb\\n' > fake-make && chmod +x fake-make
        """)
        let tools = try XCTUnwrap(app.devTools)

        await tools.runDoctor(host: host, projectPath: "~/\(folder)", project: .theos, scheme: nil)
        let report = try XCTUnwrap(tools.report(hostID: host.id, projectPath: "~/\(folder)"))
        XCTAssertEqual(report.outputs, [.theosPackage])
        XCTAssertEqual(report.hostName, "Test sshd")
        XCTAssertTrue(tools.console.lines.contains { $0.source == .doctor && $0.host == "Test sshd (hcgtest@127.0.0.1:2222)" })

        let plan = try BuildPlanner.plan(host: host, projectPath: "~/\(folder)", system: .theos, action: .build, gnuMake: "./fake-make")
        let jobID = await tools.start(plan, doctorReportID: report.id)
        for _ in 0..<60 {
            if let job = tools.job(jobID), !job.state.isActive { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let job = try XCTUnwrap(tools.job(jobID))
        XCTAssertEqual(job.state, .succeeded)
        let jobLines = tools.console.filtered(job: job.shortID).map(\.text)
        XCTAssertTrue(jobLines.contains("using password [REDACTED]"), "the host's saved password is removed before storage: \(jobLines)")
        let artifact = try XCTUnwrap(job.artifacts.first)
        XCTAssertEqual(artifact.kind, .deb)

        let downloaded = await tools.download(artifact, from: job)
        let record = try XCTUnwrap(downloaded, tools.lastError ?? "")
        XCTAssertEqual(record.sha256, artifact.sha256)
        XCTAssertEqual(record.verification, .remoteChecksumMatched)
        XCTAssertEqual(record.buildRunID, job.id)
        let options = await tools.installOptions(for: artifact, job: job)
        XCTAssertEqual(options.options.map(\.id), ["download"], "Vanilla has no package install; it says so instead")
        XCTAssertTrue(options.notOffered.contains { $0.contains("Unleashed") })

        await tools.remove(jobID)
        _ = try await connection.run("rm -rf ~/\(folder)")
        await app.disconnect(host)
    }
}
