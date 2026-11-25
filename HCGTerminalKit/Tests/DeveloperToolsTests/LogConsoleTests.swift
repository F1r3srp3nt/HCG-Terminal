import Diagnostics
import XCTest

final class SecretRedactionTests: XCTestCase {
    let redactor = SecretRedactor()

    func testRedactsTokensButKeepsContext() {
        let cases: [(String, String)] = [
            ("Authorization: Bearer abcdef1234567890XYZ", "Authorization: Bearer [REDACTED]"),
            ("curl -H 'Authorization: token ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' https://api", "curl -H 'Authorization: token [REDACTED]' https://api"),
            ("git clone https://deploy:s3cretPass@github.com/x/y", "git clone https://deploy:[REDACTED]@github.com/x/y"),
            ("export API_KEY=abcd1234efgh", "export API_KEY=[REDACTED]"),
            (#"{"password": "hunter22", "user": "me"}"#, #"{"password": "[REDACTED]", "user": "me"}"#),
            ("xcrun notarytool history --password abcd-efgh-ijkl", "xcrun notarytool history --password [REDACTED]"),
            ("dotnet build /p:SigningPassword=TopSecret1", "dotnet build /p:SigningPassword=[REDACTED]"),
            ("aws key AKIAABCDEFGHIJKLMNOP used", "aws key [REDACTED] used"),
            ("slack xoxb-1234567890-abcdefghij", "slack [REDACTED]"),
            ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop", "jwt [REDACTED]"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(redactor.redact(input), expected, input)
        }
    }

    func testOrdinaryBuildOutputIsUnchanged() {
        let lines = [
            "CompileSwift normal arm64 /Users/me/App/Sources/TokenView.swift (in target 'App' from project 'App')",
            "note: Using codesigning identity override: -",
            "Signing Identity:     \"Apple Development: Jane Doe (ABCDE12345)\"",
            "    export PATH=/usr/bin:/bin",
            "Build succeeded: password reset screen compiled",
        ]
        for line in lines { XCTAssertEqual(redactor.redact(line), line) }
    }

    func testKnownLiteralSecretsAndPEMBlocks() {
        let withPassword = redactor.adding(["correct horse battery"])
        XCTAssertEqual(withPassword.redact("echo correct horse battery | sudo -S"), "echo [REDACTED] | sudo -S")
        let pem = "before\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\nAAAAAAAAAA==\n-----END OPENSSH PRIVATE KEY-----\nafter"
        let out = redactor.redactText(pem)
        XCTAssertFalse(out.contains("b3BlbnNzaC1rZXktdjEAAAAA"))
        XCTAssertTrue(out.contains("before") && out.contains("after"))
    }

    func testConsoleRedactsBeforeStorageAndExport() {
        var buffer = ConsoleBuffer(capacity: 100)
        buffer.append(["token=abcdef123456 used for fetch"], source: .build, host: "Mac", job: "J1")
        XCTAssertEqual(buffer.lines.first?.text, "token=[REDACTED] used for fetch")
        XCTAssertFalse(ConsoleBuffer.export(buffer.lines).contains("abcdef123456"))
    }

    func testLineAssemblerJoinsSplitSecrets() {
        var assembler = LineAssembler()
        XCTAssertEqual(assembler.append("Authorization: Bearer abcdef12"), [])
        let lines = assembler.append("34567890XYZ\nnext\r50%\r100%\n")
        XCTAssertEqual(lines.map(redactor.redact), ["Authorization: Bearer [REDACTED]", "100%"])
    }
}

final class LogClassifierTests: XCTestCase {
    func testWordErrorAloneIsNotAFailure() {
        for line in [
            "CompileSwift normal arm64 /Users/me/App/ErrorView.swift (in target 'App')",
            "SwiftCompile normal arm64 Compiling\\ Errors.swift",
            "    0 Error(s)",
            "clang -Werror -Wall -c main.c",
            "Executed 12 tests, with 0 failures (0 unexpected) in 0.5 seconds",
            "Ld /path/ErrorReporting.framework/ErrorReporting normal",
            "** BUILD SUCCEEDED **",
        ] {
            XCTAssertNotEqual(LogClassifier.classify(line).severity, .error, line)
        }
    }

    func testStructuredFailures() {
        XCTAssertEqual(LogClassifier.classify("/Users/me/App/View.swift:12:5: error: cannot find 'foo' in scope"), LineClassification(severity: .error, failure: .compiler))
        XCTAssertEqual(LogClassifier.classify("Program.cs(3,9): error CS0103: The name 'x' does not exist [/p/App.csproj]").failure, .compiler)
        XCTAssertEqual(LogClassifier.classify("Undefined symbols for architecture arm64:").failure, .linker)
        XCTAssertEqual(LogClassifier.classify("xcodebuild: error: The project named \"App\" does not contain a scheme named \"Nope\".").failure, .tool)
        XCTAssertEqual(LogClassifier.classify("error: No profiles for 'com.example.app' were found").failure, .signing)
        XCTAssertEqual(LogClassifier.classify("make: *** [all] Error 2").failure, .summary)
        XCTAssertEqual(LogClassifier.classify("make: *** No rule to make target 'x'.  Stop.").failure, .tool)
        XCTAssertEqual(LogClassifier.classify("** BUILD FAILED **").failure, .summary)
        XCTAssertEqual(LogClassifier.classify("==> Error: The vendor/include and/or vendor/lib directories are missing.").failure, .tool)
        XCTAssertEqual(LogClassifier.classify("/bin/sh: ldid: command not found").failure, .tool)
        XCTAssertEqual(LogClassifier.classify("/p/File.swift:3:1: warning: unused").severity, .warning)
    }

    func testFirstFailurePrefersSpecificOverSummary() {
        let lines = [
            "Build settings from command line:",
            "CompileSwift normal arm64 /p/ErrorView.swift",
            "/p/A.swift:10:3: error: missing return",
            "/p/B.swift:4:1: error: later error",
            "** BUILD FAILED **",
            "The following build commands failed:",
        ]
        let failure = FailureLocator.firstFailure(in: lines, context: 2)
        XCTAssertEqual(failure?.lineIndex, 2)
        XCTAssertEqual(failure?.before, ["Build settings from command line:", "CompileSwift normal arm64 /p/ErrorView.swift"])
        XCTAssertEqual(failure?.after.count, 2)
        // Only a summary: it is reported, marked as summary-only.
        let summary = FailureLocator.firstFailure(in: ["Building", "make: *** [all] Error 2"])
        XCTAssertEqual(summary?.isSummaryOnly, true)
        XCTAssertNil(FailureLocator.firstFailure(in: ["all good", "0 errors"]))
    }

    func testBufferIsBoundedAndKeepsFirstFailure() {
        var buffer = ConsoleBuffer(capacity: 100)
        buffer.append(["/p/A.swift:1:1: error: first"], source: .build, host: "Mac", job: "J")
        buffer.append((0..<250).map { "line \($0)" }, source: .build, host: "Mac", job: "J")
        buffer.append(["** BUILD FAILED **"], source: .build, host: "Mac", job: "J")
        XCTAssertEqual(buffer.lines.count, 100)
        XCTAssertEqual(buffer.droppedCount, 152)
        XCTAssertEqual(buffer.firstFailures["J"]?.text, "/p/A.swift:1:1: error: first")
        XCTAssertEqual(buffer.filtered(minimumSeverity: .error).map(\.text), ["** BUILD FAILED **"])
        XCTAssertEqual(buffer.filtered(search: "LINE 249").count, 1)
    }
}
