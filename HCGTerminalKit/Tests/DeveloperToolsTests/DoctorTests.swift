import BuildOrchestrator
@testable import DeveloperWorkspace
import Diagnostics
import Foundation
import TerminalCore
import XCTest
#if os(macOS) || os(Linux)
import TerminalTestSupport
#endif

final class DoctorTests: XCTestCase {
    let host = HostProfile(name: "Build Mac", hostname: "mac.local", username: "me", auth: .password)

    // MARK: Fixtures for a Mac (this suite also runs on Linux)

    func macFacts(_ extra: String = "") -> DoctorFacts {
        DoctorFacts.parse("""
        K\tos.kernel\tDarwin
        K\tos.arch\tarm64
        K\tos.product\tmacOS 15.5
        K\tenv.shell\t/bin/zsh
        K\tenv.path\t/opt/homebrew/bin:/usr/bin:/bin
        K\tproject.dir\t/Users/me/App
        K\tdisk.project_kb\t52428800
        K\tdisk.mount\t/System/Volumes/Data
        K\ttool.xcodebuild\t/usr/bin/xcodebuild
        K\txcode.select\t/Applications/Xcode.app/Contents/Developer
        K\txcode.app\t/Applications/Xcode.app
        BEGIN\txcode.version
        Xcode 26.1
        Build version 17B55
        END\txcode.version
        K\txcode.first_launch_status\t0
        K\tsdk.iphoneos\t26.1
        K\tsdk.iphonesimulator\t26.1
        K\tsdk.macosx\t26.1
        BEGIN\tsimulator.runtimes
        iOS 26.1 (26.1 - 23B80) - com.apple.CoreSimulator.SimRuntime.iOS-26-1
        END\tsimulator.runtimes
        BEGIN\txcode.list
        {"project":{"name":"App","schemes":["App","AppTests"],"targets":["App"]}}
        END\txcode.list
        BEGIN\txcode.settings
        [{"target":"App","buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.application","IPHONEOS_DEPLOYMENT_TARGET":"17.0","SDKROOT":"iphoneos","SUPPORTED_PLATFORMS":"iphoneos iphonesimulator","PRODUCT_BUNDLE_IDENTIFIER":"com.example.app","DEVELOPMENT_TEAM":"ABCDE12345","CODE_SIGN_STYLE":"Automatic"}}]
        END\txcode.settings
        K\ttool.dotnet\t/usr/local/share/dotnet/dotnet
        BEGIN\tdotnet.version
        10.0.100
        END\tdotnet.version
        BEGIN\tdotnet.sdks
        8.0.404 [/usr/local/share/dotnet/sdk]
        10.0.100 [/usr/local/share/dotnet/sdk]
        END\tdotnet.sdks
        K\tem.path\t/Users/me/HCG-Executable-Maker
        K\tem.revision\t21c0cc5
        BEGIN\tsigning.identities
          1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Jane Doe (XYZ9876543)"
             1 valid identities found
        END\tsigning.identities
        PROFILE\tiOS Team Provisioning Profile: com.example.app\tABCDE12345\t2099-01-01T00:00:00Z\tABCDE12345.com.example.app\t\ttrue\t00008110-AAAA,00008120-BBBB\tabc.mobileprovision
        \(extra)
        K\tprobe.done\t1
        """)
    }

    func evaluate(_ facts: DoctorFacts, project: ProjectKind? = .xcodeProject("App.xcodeproj")) -> DoctorReport {
        DoctorEvaluator.evaluate(facts: facts, host: host, projectPath: "~/App", project: project, scheme: "App")
    }

    func check(_ report: DoctorReport, _ id: String) -> DoctorCheck? { report.checks.first { $0.id == id } }

    func testHealthyMacProjectPassesWithEvidence() {
        let report = evaluate(macFacts())
        XCTAssertEqual(report.outputs, [.iosSimulatorApp, .iosArchive, .iosIPA])
        for id in ["host", "disk", "xcode", "sdks", "schemes", "deployment", "executable-maker", "signing", "dotnet"] {
            XCTAssertEqual(check(report, id)?.status, .passed, "\(id): \(check(report, id)?.summary ?? "missing")")
        }
        XCTAssertEqual(report.schemes, ["App", "AppTests"])
        XCTAssertEqual(report.environment.iosDeploymentTarget, "17.0")
        XCTAssertEqual(report.environment.executableMakerPath, "/Users/me/HCG-Executable-Maker")
        XCTAssertTrue(check(report, "xcode")!.evidence.contains { $0.label == "xcode-select -p" })
        XCTAssertTrue(report.blockers(for: .iosSimulatorApp).isEmpty)
    }

    func testXcodeInstalledButCommandLineToolsSelectedIsNotInEnvironment() {
        var facts = macFacts()
        facts.values["xcode.select"] = ["/Library/Developer/CommandLineTools"]
        let xcode = check(evaluate(facts), "xcode")!
        XCTAssertEqual(xcode.status, .blocked)
        XCTAssertEqual(xcode.presence, .notInEnvironment(path: "/Applications/Xcode.app"))
        XCTAssertTrue(xcode.nextSteps.first!.contains("xcode-select -s /Applications/Xcode.app"))
        XCTAssertTrue(xcode.affects.contains(.iosSimulatorApp))
    }

    func testNoXcodeAtAllIsNotInstalled() {
        var facts = macFacts()
        facts.values["xcode.select"] = ["/Library/Developer/CommandLineTools"]
        facts.values["xcode.app"] = nil
        XCTAssertEqual(check(evaluate(facts), "xcode")?.presence, .notInstalled)
    }

    func testDeploymentTargetNewerThanSDKIsIncompatible() {
        var facts = macFacts()
        facts.values["sdk.iphoneos"] = ["18.5"]
        let deployment = check(evaluate(facts), "deployment")!
        // 17.0 <= 18.5 passes; raise the target above the SDK.
        XCTAssertEqual(deployment.status, .passed)
        facts.blocks["xcode.settings"] = facts.blocks["xcode.settings"]!.replacingOccurrences(of: "\"17.0\"", with: "\"19.0\"")
        let blocked = check(evaluate(facts), "deployment")!
        XCTAssertEqual(blocked.status, .blocked)
        if case .incompatible = blocked.presence {} else { XCTFail("\(String(describing: blocked.presence))") }
    }

    func testDotnetGlobalJsonMismatchIsInstalledButIncompatible() {
        var facts = macFacts()
        facts.blocks["dotnet.version"] = "A compatible .NET SDK was not found.\nRequested SDK version: 9.0.100\nglobal.json file: /Users/me/App/global.json"
        let dotnet = check(evaluate(facts, project: .dotnetProject("App.csproj")), "dotnet")!
        XCTAssertEqual(dotnet.status, .blocked)
        XCTAssertEqual(dotnet.presence, .incompatible(reason: "global.json"))
    }

    func testDotnetInstalledOutsidePathIsNotFoundInThisEnvironment() {
        var facts = macFacts()
        facts.values["tool.dotnet"] = nil
        facts.values["candidate.dotnet"] = ["/usr/local/share/dotnet/dotnet"]
        let dotnet = check(evaluate(facts, project: .dotnetSolution("App.sln")), "dotnet")!
        XCTAssertEqual(dotnet.presence, .notInEnvironment(path: "/usr/local/share/dotnet/dotnet"))
        XCTAssertTrue(dotnet.nextSteps.first!.contains("/usr/local/share/dotnet"))
    }

    func testDotnetTargetFrameworkNewerThanSDK() {
        var facts = macFacts()
        facts.blocks["dotnet.version"] = "8.0.404"
        facts.blocks["dotnet.frameworks"] = "App.csproj\t<TargetFramework>net9.0</TargetFramework>"
        let dotnet = check(evaluate(facts, project: .dotnetProject("App.csproj")), "dotnet")!
        XCTAssertEqual(dotnet.status, .blocked)
        XCTAssertEqual(dotnet.presence, .incompatible(reason: "SDK 8.0.404 < net9"))
    }

    func testExecutableMakerNeedsDotnet10() {
        var facts = macFacts()
        facts.blocks["dotnet.sdks"] = "8.0.404 [/usr/local/share/dotnet/sdk]"
        facts.blocks["dotnet.version"] = "8.0.404"
        let report = evaluate(facts)
        XCTAssertEqual(check(report, "dotnet")?.status, .blocked)
        XCTAssertFalse(report.blockers(for: .iosSimulatorApp).isEmpty)
    }

    func testMissingExecutableMakerBlocksOnlyItsOutputs() {
        var facts = macFacts()
        facts.values["em.path"] = nil
        let report = evaluate(facts)
        let em = check(report, "executable-maker")!
        XCTAssertEqual(em.status, .blocked)
        XCTAssertEqual(em.presence, .notInstalled)
        XCTAssertEqual(Set(em.affects), [.iosSimulatorApp, .iosArchive, .iosIPA])
        XCTAssertTrue(em.nextSteps.contains { $0.contains("Direct xcodebuild") })
    }

    func testSigningStates() {
        // No identities: IPA blocked, archive not.
        var facts = macFacts()
        facts.blocks["signing.identities"] = "     0 valid identities found"
        let none = check(evaluate(facts), "signing")!
        XCTAssertEqual(none.status, .blocked)
        XCTAssertEqual(none.affects, [.iosIPA])
        // Automatic signing, no matching profile: unknown (cannot be checked without building).
        facts = macFacts()
        facts.profiles = []
        XCTAssertEqual(check(evaluate(facts), "signing")?.status, .unknown)
        // Manual with only an expired profile: blocked.
        facts = macFacts()
        facts.blocks["xcode.settings"] = facts.blocks["xcode.settings"]!.replacingOccurrences(of: "Automatic", with: "Manual")
        facts.profiles[0].expiration = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(check(evaluate(facts), "signing")?.status, .blocked)
    }

    func testProfileKindsAndCoverage() {
        let profile = macFacts().profiles[0]
        XCTAssertEqual(profile.kind, .development)
        XCTAssertEqual(profile.deviceUDIDs, ["00008110-AAAA", "00008120-BBBB"])
        XCTAssertTrue(profile.covers(bundleID: "com.example.app"))
        XCTAssertFalse(profile.covers(bundleID: "com.example.other"))
        var wildcard = profile
        wildcard.applicationIdentifier = "ABCDE12345.com.example.*"
        XCTAssertTrue(wildcard.covers(bundleID: "com.example.other"))
    }

    func testTheosChecks() {
        let base = """
        K\tos.kernel\tDarwin
        K\tenv.theos\t
        K\ttheos.dir\t/Users/me/theos
        BEGIN\ttheos.sdks./Users/me/theos
        iPhoneOS16.5.sdk
        END\ttheos.sdks./Users/me/theos
        BEGIN\ttheos.makefile
        TARGET := iphone:clang:16.5:14.0
        include $(THEOS)/makefiles/common.mk
        END\ttheos.makefile
        K\ttool.make\t/usr/bin/make
        K\tmake.version./usr/bin/make\tGNU Make 3.81
        K\tcandidate.ldid\t/opt/homebrew/bin/ldid
        K\tprobe.done\t1
        """
        var report = evaluate(DoctorFacts.parse(base), project: .theos)
        XCTAssertEqual(report.outputs, [.theosPackage])
        XCTAssertEqual(check(report, "theos")?.presence, .notInEnvironment(path: "/Users/me/theos"))
        XCTAssertEqual(check(report, "make")?.presence, .incompatible(reason: "GNU Make 3.81"))
        XCTAssertEqual(check(report, "ldid")?.presence, .notInEnvironment(path: "/opt/homebrew/bin/ldid"))
        XCTAssertEqual(check(report, "dpkg-deb")?.presence, .notInstalled)

        // THEOS set, newer make available by path, SDK missing.
        let fixed = base.replacingOccurrences(of: "K\tenv.theos\t", with: "K\tenv.theos\t/Users/me/theos")
            .replacingOccurrences(of: "16.5:14.0", with: "17.0:15.0")
            + "\nK\tmake.version./opt/homebrew/opt/make/libexec/gnubin/make\tGNU Make 4.4.1"
        report = evaluate(DoctorFacts.parse(fixed), project: .theos)
        XCTAssertEqual(check(report, "theos")?.presence, .incompatible(reason: "SDK 17.0 missing"))
        XCTAssertEqual(check(report, "make")?.status, .passed)
        XCTAssertEqual(report.environment.gnuMake, "/opt/homebrew/opt/make/libexec/gnubin/make")
    }

    func testLinuxHostCannotBuildXcodeProjects() {
        let facts = DoctorFacts.parse("K\tos.kernel\tLinux\nK\tos.product\tUbuntu 24.04\nK\tprobe.done\t1")
        let report = evaluate(facts)
        XCTAssertEqual(check(report, "host")?.status, .blocked)
    }

    func testIncompleteProbeIsReportedAsUnknown() {
        let report = evaluate(DoctorFacts.parse("K\tos.kernel\tDarwin"))
        XCTAssertFalse(report.complete)
        XCTAssertEqual(check(report, "probe")?.status, .unknown)
    }

    func testVersionComparison() {
        XCTAssertLessThan(Version("17.0"), Version("17.0.1"))
        XCTAssertLessThan(Version("9.0"), Version("10.0"))
        XCTAssertEqual(Version("17"), Version("17.0.0"))
        XCTAssertGreaterThanOrEqual(Version("10.0.100"), Version("10.0.100"))
    }

    // MARK: Executable Maker CLI

    func testExecutableMakerCommandAndOutputParsing() throws {
        let build = ExecutableMakerBuild(output: .iosSimulatorApp, toolPath: "~/HCG-Executable-Maker")
        let command = try ExecutableMakerCLI.command(build, configuration: .debug)
        XCTAssertTrue(command.contains("dotnet run --no-cache tools/mobile-build/mobile-build.cs -- \"$HCG_PROJECT_DIR\" \"$HCG_JOB_DIR/output\" --output ios-simulator --signing project"))
        XCTAssertTrue(command.hasSuffix("--trust"))
        XCTAssertTrue(command.contains("HCG_EXECUTABLE_MAKER_HOME=\"$HOME/Library/Application Support/HCG/ExecutableMaker\""))
        XCTAssertThrowsError(try ExecutableMakerCLI.command(ExecutableMakerBuild(output: .iosIPA, toolPath: "x", signing: .init(mode: .unsigned)), configuration: .release))
        XCTAssertThrowsError(try ExecutableMakerCLI.command(ExecutableMakerBuild(output: .iosArchive, toolPath: "x", signing: .init(mode: .automatic, team: "bad")), configuration: .release))
        let ipa = try ExecutableMakerCLI.command(ExecutableMakerBuild(output: .iosIPA, toolPath: "x", signing: .init(mode: .manual, team: "ABCDE12345", profile: "My Profile")), configuration: .release)
        XCTAssertTrue(ipa.contains("--signing manual --profile 'My Profile' --team ABCDE12345 --export debugging"))
        // Never an App Store Connect export or upload.
        XCTAssertNoThrow(try PublishingGuard.check(ipa))

        let output = """
           [Preparing] Importing project
           [Compiling] xcodebuild build
           OUTPUT: CompileSwift normal arm64 /x/ErrorView.swift
        Result: Succeeded  in 00:01:12.5
          /Users/me/.hcg-terminal/jobs/abc/output/App-ci-ios-simulator/App.app  12,345,678 bytes  sha256=ABCDEF0123  Passed
             - Platform: Passed — iphonesimulator
        History: build 0f8fad5b-d9cb-469f-a165-70867728950e persisted as Succeeded with 1 artifact(s).
        """
        let report = ExecutableMakerCLI.parse(output.components(separatedBy: "\n"))
        XCTAssertEqual(report.stages, ["Preparing: Importing project", "Compiling: xcodebuild build"])
        XCTAssertEqual(report.result, "Succeeded")
        XCTAssertEqual(report.artifacts.first?.path, "/Users/me/.hcg-terminal/jobs/abc/output/App-ci-ios-simulator/App.app")
        XCTAssertEqual(report.artifacts.first?.size, 12_345_678)
        XCTAssertEqual(report.artifacts.first?.sha256, "abcdef0123")
        XCTAssertEqual(report.artifacts.first?.verification, "Passed")
        XCTAssertEqual(report.artifacts.first?.checks, ["Platform: Passed — iphonesimulator"])
        XCTAssertEqual(report.buildID, "0f8fad5b-d9cb-469f-a165-70867728950e")
    }

    func testProjectDetectorFindsTheos() {
        let entries = [RemoteEntry(name: "Makefile", path: "/p/Makefile", kind: .file), RemoteEntry(name: "control", path: "/p/control", kind: .file)]
        XCTAssertEqual(ProjectDetector.detect(entries), [.theos])
    }

    // MARK: The real probe script, run locally

    #if os(macOS) || os(Linux)
    func testProbeScriptRunsAndIsReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-\(UUID().uuidString.prefix(8))")
        let project = root.appendingPathComponent("home/My Tweak")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "TARGET := iphone:clang:16.5:14.0\ninclude $(THEOS)/makefiles/common.mk\n".write(to: project.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        try "Package: com.example.tweak\nVersion: 1.0\nArchitecture: iphoneos-arm64\n".write(to: project.appendingPathComponent("control"), atomically: true, encoding: .utf8)
        try "<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>".write(to: project.appendingPathComponent("Tool.csproj"), atomically: true, encoding: .utf8)
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()

        let executor = LocalShellExecutor(home: root.appendingPathComponent("home").path)
        let command = DoctorProbe.command(projectPath: "~/My Tweak", project: .theos, scheme: nil, executableMakerPath: nil)
        let result = try await executor.run(command)
        let facts = DoctorFacts.parse(result.stdoutText)
        XCTAssertTrue(facts.isComplete, result.stdoutText + result.stderrText)
        XCTAssertEqual(facts.value("project.dir"), project.path)
        XCTAssertNotNil(facts.value("os.kernel"))
        XCTAssertNotNil(facts.value("disk.project_kb").flatMap(Int64.init))
        XCTAssertTrue(facts.block("theos.makefile")?.contains("TARGET := iphone:clang:16.5:14.0") == true)
        XCTAssertTrue(facts.block("dotnet.frameworks")?.contains("net8.0") == true)

        let report = DoctorEvaluator.evaluate(facts: facts, host: host, projectPath: "~/My Tweak", project: .theos, scheme: nil)
        XCTAssertEqual(report.outputs, [.theosPackage])
        XCTAssertEqual(check(report, "theos")?.presence, .notInstalled)
        // This machine's own make is reported with its real version.
        if let make = facts.value("tool.make") {
            XCTAssertTrue(check(report, "make")!.evidence.contains { $0.label == make })
        }
        // Read-only: nothing was created or changed in the project or the home folder.
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), before)
    }
    #endif
}
