@testable import BuildOrchestrator
import Foundation
import XCTest

final class InstallHandoffTests: XCTestCase {
    let mac = DoctorEnvironment(shell: "/bin/zsh", path: nil, operatingSystem: "macOS 15.5", architecture: "arm64", isMac: true, developerDirectory: nil, theosDirectory: nil, gnuMake: nil, executableMakerPath: nil, executableMakerRevision: nil, bundleIdentifier: nil, developmentTeam: nil, codeSignStyle: nil, iosDeploymentTarget: nil, simulatorRuntimes: [], signingIdentities: [], profiles: [])

    func artifact(_ kind: ArtifactKind, name: String = "App.app", source: String = "/Users/me/out/App.app", minimumOS: String? = "17.0") -> JobArtifact {
        JobArtifact(kind: kind, name: name, remotePath: "/Users/me/.hcg-terminal/jobs/x/artifacts/\(name).zip", sourcePath: source, size: 10, sha256: "ab", bundleIdentifier: "com.example.app", minimumOS: minimumOS, platform: nil, verification: nil, checks: [], jobID: UUID())
    }

    func profile(devices: [String], getTaskAllow: Bool = true, all: Bool = false, expires: Date = .distantFuture) -> ProvisioningProfileInfo {
        ProvisioningProfileInfo(name: "Dev", teamID: "ABCDE12345", expiration: expires, applicationIdentifier: "ABCDE12345.com.example.app", provisionsAllDevices: all, getTaskAllow: getTaskAllow, deviceUDIDs: devices, fileName: "embedded")
    }

    func testSimulatorAppOffersOnlyCompatibleSimulators() {
        let sims = [
            SimulatorDevice(udid: "A", name: "iPhone 17", runtime: "iOS 26.1", runtimeVersion: "26.1", state: "Shutdown"),
            SimulatorDevice(udid: "B", name: "iPhone 12", runtime: "iOS 16.4", runtimeVersion: "16.4", state: "Booted"),
        ]
        let options = InstallPlanner.options(for: artifact(.simulatorApp), buildHost: "Build Mac", hostEnvironment: mac, simulators: sims)
        XCTAssertEqual(options.options.map(\.id), ["download", "sim-A"])
        XCTAssertTrue(options.compatibility.first!.contains("cannot be installed on an iPhone"))
        let none = InstallPlanner.options(for: artifact(.simulatorApp), buildHost: "Build Mac", hostEnvironment: mac, simulators: [])
        XCTAssertEqual(none.options.map(\.id), ["download"])
        XCTAssertTrue(none.notOffered.first!.contains("No iOS Simulator"))
    }

    func testDevelopmentSignedIPAOffersOnlyRegisteredDevicesTheMacSees() {
        let signing = SigningInspection(isSigned: true, authority: "Apple Development: Jane", teamIdentifier: "ABCDE12345", profile: profile(devices: ["UDID-1"]), codesignOutput: "")
        let devices = [HostVisibleDevice(udid: "udid-1", name: "Jane's iPhone"), HostVisibleDevice(udid: "UDID-2", name: "Other iPad")]
        let result = InstallPlanner.options(for: artifact(.ipa, name: "App.ipa"), buildHost: "Build Mac", hostEnvironment: mac, signing: signing, hostDevices: devices)
        XCTAssertEqual(result.options.map(\.id), ["download", "dev-udid-1"])
        XCTAssertTrue(result.notOffered.contains { $0.contains("Other iPad") })
        XCTAssertTrue(result.notOffered.contains { $0.contains("cannot read its own device ID") })
    }

    func testUnsignedDistributionAndExpiredBuildsOfferNoInstall() {
        let devices = [HostVisibleDevice(udid: "UDID-1", name: "Phone")]
        let unsigned = InstallPlanner.options(for: artifact(.deviceApp), buildHost: "Mac", hostEnvironment: mac, signing: SigningInspection(isSigned: false, codesignOutput: "code object is not signed at all"), hostDevices: devices)
        XCTAssertEqual(unsigned.options.map(\.id), ["download"])
        XCTAssertTrue(unsigned.notOffered.first!.contains("not signed"))
        let appStore = InstallPlanner.options(for: artifact(.ipa), buildHost: "Mac", hostEnvironment: mac, signing: SigningInspection(isSigned: true, authority: "Apple Distribution", profile: profile(devices: [], getTaskAllow: false), codesignOutput: ""), hostDevices: devices)
        XCTAssertEqual(appStore.options.map(\.id), ["download"])
        XCTAssertTrue(appStore.notOffered.first!.contains("never uploads"))
        let expired = InstallPlanner.options(for: artifact(.ipa), buildHost: "Mac", hostEnvironment: mac, signing: SigningInspection(isSigned: true, authority: "x", profile: profile(devices: ["UDID-1"], expires: Date(timeIntervalSince1970: 0)), codesignOutput: ""), hostDevices: devices)
        XCTAssertEqual(expired.options.map(\.id), ["download"])
        let archive = InstallPlanner.options(for: artifact(.xcarchive), buildHost: "Mac", hostEnvironment: mac)
        XCTAssertTrue(archive.notOffered.first!.contains("Export a signed IPA"))
    }

    func testDebHandoffOnlyWhenTheAppCanInstallPackages() {
        let deb = artifact(.deb, name: "tweak.deb", source: "/p/packages/tweak.deb")
        XCTAssertEqual(InstallPlanner.options(for: deb, buildHost: "Mac", hostEnvironment: mac, appSupportsLocalPackageInstall: true).options.map(\.id), ["download", "deb"])
        let vanilla = InstallPlanner.options(for: deb, buildHost: "Mac", hostEnvironment: mac, appSupportsLocalPackageInstall: false)
        XCTAssertEqual(vanilla.options.map(\.id), ["download"])
        XCTAssertTrue(vanilla.notOffered.first!.contains("Unleashed"))
    }

    func testDesktopProductsNameTheirHost() {
        let rid = artifact(.dotnetOutput, name: "Tool.dll", source: "/p/bin/Release/net8.0/win-x64/Tool.dll")
        XCTAssertTrue(InstallPlanner.options(for: rid, buildHost: "Mac", hostEnvironment: mac).compatibility.first!.contains("Windows (x64)"))
        let fdd = artifact(.dotnetOutput, name: "Tool.dll", source: "/p/bin/Release/net8.0/Tool.dll")
        XCTAssertTrue(InstallPlanner.options(for: fdd, buildHost: "Mac", hostEnvironment: mac).compatibility.first!.contains("Framework-dependent"))
        let macApp = artifact(.macApp, minimumOS: "14.0")
        let text = InstallPlanner.options(for: macApp, buildHost: "Build Mac", hostEnvironment: mac).compatibility.first!
        XCTAssertTrue(text.contains("Build Mac") && text.contains("macOS 15.5 (arm64)") && text.contains("macOS 14.0"), text)
    }

    func testParsers() {
        let simJSON = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-1":[{"udid":"U1","name":"iPhone 17","state":"Booted","isAvailable":true}],"com.apple.CoreSimulator.SimRuntime.watchOS-11-0":[{"udid":"W","name":"Watch","state":"Shutdown","isAvailable":true}]}}"#
        let sims = InstallInspection.parseSimulators(Data(simJSON.utf8))
        XCTAssertEqual(sims, [SimulatorDevice(udid: "U1", name: "iPhone 17", runtime: "iOS 26.1", runtimeVersion: "26.1", state: "Booted")])

        let devJSON = #"{"result":{"devices":[{"hardwareProperties":{"udid":"00008110-AAAA"},"deviceProperties":{"name":"Jane's iPhone","osVersionNumber":"26.1"},"connectionProperties":{"pairingState":"paired","tunnelState":"connected"}}]}}"#
        XCTAssertEqual(InstallInspection.parseDevices(Data(devJSON.utf8)).first?.name, "Jane's iPhone")

        let signing = InstallInspection.parseSigning("""
        BEGIN\tcodesign
        Executable=/x/App.app/App
        Authority=Apple Development: Jane Doe (XYZ)
        TeamIdentifier=ABCDE12345
        END\tcodesign
        PROFILE\tDev\tABCDE12345\t2099-01-01T00:00:00Z\tABCDE12345.com.example.app\t\ttrue\tU1,U2\tembedded
        K\tprobe.done\t1
        """)
        XCTAssertTrue(signing.isSigned)
        XCTAssertEqual(signing.teamIdentifier, "ABCDE12345")
        XCTAssertEqual(signing.profile?.deviceUDIDs, ["U1", "U2"])
        XCTAssertFalse(InstallInspection.parseSigning("BEGIN\tcodesign\n/x/App.app: code object is not signed at all\nEND\tcodesign").isSigned)
    }

    func testInstallOutcomeNeedsTheMarkers() {
        XCTAssertEqual(InstallCommands.outcome(output: "Installing…\nHCG_INSTALLED\ncom.x: 4242\nHCG_LAUNCHED 4242", exitStatus: 0), .installedAndLaunched(pid: "4242"))
        XCTAssertEqual(InstallCommands.outcome(output: "Installing…\nHCG_INSTALLED", exitStatus: 3), .installed)
        // Exit 0 without the marker is not an install.
        XCTAssertEqual(InstallCommands.outcome(output: "something", exitStatus: 0), .failed(exitStatus: 0))
        XCTAssertTrue(InstallCommands.simulator(appPath: "/a b/App.app", udid: "U1", bundleID: "com.x").contains("simctl install"))
    }
}
