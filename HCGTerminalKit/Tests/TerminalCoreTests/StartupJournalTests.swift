import Foundation
@testable import TerminalCore
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class StartupJournalTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testFirstLaunchHasNoPreviousFailure() throws {
        let journal = StartupJournal.begin(directory: try makeDirectory(), header: [("version", "0.2.0")], installCrashHandlers: false)
        XCTAssertNil(journal.previous)
        XCTAssertTrue(journal.reportText().contains("version: 0.2.0"))
    }

    func testLaunchThatNeverBecameReadyIsReportedWithItsLastPhase() throws {
        let directory = try makeDirectory()
        let first = StartupJournal.begin(directory: directory, installCrashHandlers: false)
        first.phase("environment detection")
        // The process "dies" here: no markReady.
        let second = StartupJournal.begin(directory: directory, installCrashHandlers: false)
        XCTAssertEqual(second.previous?.lastPhase, "environment detection")
        XCTAssertNil(second.previous?.signal)
        XCTAssertTrue(second.previous?.summary.contains("without reporting a crash") ?? false)
        XCTAssertTrue(second.previous?.log.contains("phase environment detection") ?? false)
        XCTAssertTrue(second.reportText().contains("-- earlier launch --"))
    }

    func testCleanLaunchIsNotReported() throws {
        let directory = try makeDirectory()
        let first = StartupJournal.begin(directory: directory, installCrashHandlers: false)
        first.phase("interface")
        first.markReady()
        first.phase("later work after startup")
        let second = StartupJournal.begin(directory: directory, installCrashHandlers: false)
        XCTAssertNil(second.previous)
    }

    func testUnwritableDirectoryDoesNotStopTheLaunch() {
        let journal = StartupJournal.begin(directory: URL(fileURLWithPath: "/proc/hcg-not-writable/startup"), installCrashHandlers: false)
        journal.phase("still works")
        journal.markReady()
        XCTAssertNil(journal.previous)
        XCTAssertTrue(journal.isReady)
    }

    /// A real crash: a forked child dies from SIGABRT with the handler installed. The handler must
    /// record the signal and the phase, and the default action must still end the process.
    func testCrashSignalIsRecordedAndProcessStillDies() throws {
        let directory = try makeDirectory()
        let first = StartupJournal.begin(directory: directory, installCrashHandlers: false)
        first.phase("model")
        StartupJournal.prepareSignalPaths(log: first.logURL.path, signalFile: first.signalURL.path)

        let pid = fork()
        if pid == 0 {
            // Child: only async-signal-safe calls.
            Darwinish.installHandler(SIGABRT)
            raise(SIGABRT)
            _exit(99) // not reached if the handler re-raised with the default action
        }
        XCTAssertGreaterThan(pid, 0)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let terminatedBySignal = (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
        XCTAssertTrue(terminatedBySignal, "the child must still die from the signal, status \(status)")
        XCTAssertEqual(status & 0x7f, SIGABRT)

        let second = StartupJournal.begin(directory: directory, installCrashHandlers: false)
        XCTAssertEqual(second.previous?.lastPhase, "model")
        XCTAssertEqual(second.previous?.signal, SIGABRT)
        XCTAssertTrue(second.previous?.log.contains("!! crashed with signal \(SIGABRT) during phase model") ?? false, second.previous?.log ?? "")
        XCTAssertTrue(second.previous?.summary.contains("SIGABRT") ?? false)
    }
}
