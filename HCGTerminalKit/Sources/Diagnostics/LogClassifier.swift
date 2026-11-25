import Foundation

/// Severity of one console line.
public enum ConsoleSeverity: Int, Codable, Sendable, Comparable, CaseIterable {
    case debug, info, notice, warning, error

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .notice: "Notice"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}

/// What kind of failure a line reports.
public enum FailureKind: String, Codable, Sendable {
    /// A diagnostic with a file and line from a compiler (Swift, clang, C#).
    case compiler
    case linker
    /// A tool refused or could not run (xcodebuild: error:, command not found, missing SDK).
    case tool
    case signing
    case testFailure
    /// A follow-on summary such as "** BUILD FAILED **" or "make: *** Error 2". Only shown when
    /// nothing more specific was found.
    case summary
}

public struct LineClassification: Sendable, Equatable {
    public var severity: ConsoleSeverity
    public var failure: FailureKind?

    public init(severity: ConsoleSeverity, failure: FailureKind? = nil) {
        self.severity = severity
        self.failure = failure
    }

    static let plain = LineClassification(severity: .info)
}

/// Classifies build and tool output by its structure, not by the presence of a word.
///
/// "error" inside a file name (`ErrorView.swift`), a flag (`-Werror`), a count (`0 Error(s)`)
/// or a compile step (`CompileSwift normal arm64 …/Errors.swift`) is not a failure.
public enum LogClassifier {
    private struct Pattern {
        let regex: NSRegularExpression
        let result: LineClassification
    }

    private static func p(_ pattern: String, _ severity: ConsoleSeverity, _ failure: FailureKind? = nil, _ options: NSRegularExpression.Options = []) -> Pattern {
        Pattern(regex: try! NSRegularExpression(pattern: pattern, options: options), result: LineClassification(severity: severity, failure: failure))
    }

    /// Checked in order; the first match wins.
    private static let patterns: [Pattern] = [
        // Counts that are not failures: "0 Error(s)", "0 errors", "with 0 failures".
        p(#"^\s*0 (?:Error\(s\)|errors?|Warning\(s\)|warnings?)\s*$"#, .info),
        p(#"^\s*[1-9]\d* Error\(s\)\s*$"#, .error, .summary),
        p(#"^\s*[1-9]\d* Warning\(s\)\s*$"#, .warning),

        // Code signing and provisioning (before the generic "error:" rules).
        p(#"(?i)^(?:.*: )?(?:error: )?(?:Code ?Sign(?:ing)? error|No signing certificate|No profiles for|Provisioning profile .* (?:doesn't|does not|has expired|is not)|requires a provisioning profile|errSecInternalComponent|Signing for .* requires a development team)"#, .error, .signing),

        // Compiler diagnostics: /path/File.swift:12:5: error: … (also fatal error, note, warning).
        p(#"^.+?:\d+(?::\d+)?:\s+(?:fatal )?error:\s"#, .error, .compiler),
        p(#"^.+?:\d+(?::\d+)?:\s+warning:\s"#, .warning),
        p(#"^.+?:\d+(?::\d+)?:\s+note:\s"#, .notice),
        // MSBuild / C#: File.cs(12,5): error CS1002: … and project-level error MSB1009 / NU1101.
        p(#"^\s*.+?\(\d+,\d+\):\s+error\s+[A-Z]+\d+:"#, .error, .compiler),
        p(#"(?:^|\s)error\s+(?:MSB|NU|NETSDK)\d+:"#, .error, .tool),
        p(#"^\s*.+?\(\d+,\d+\):\s+warning\s+[A-Z]+\d+:"#, .warning),
        p(#"(?:^|\s)warning\s+(?:MSB|NU|NETSDK|CS)\d+:"#, .warning),

        // Linker.
        p(#"^Undefined symbols for architecture"#, .error, .linker),
        p(#"^ld: (?:error|warning: .*(?:not found|missing))|^ld: (?:library|framework) (?:not found|'.*' not found)|^ld: symbol\(s\) not found"#, .error, .linker),
        p(#"^(?:/.*/)?ld(?:64)?(?:\.lld)?: error:"#, .error, .linker),
        p(#"^(?:clang|clang\+\+|swiftc?|cc|gcc|g\+\+): error: linker command failed"#, .error, .summary),
        p(#"^ld: warning:"#, .warning),

        // Tests.
        p(#"^Test Case '.+' failed \("#, .error, .testFailure),
        p(#"^\s*✘ Test .+ (?:failed|recorded an issue)"#, .error, .testFailure),
        p(#"^\s*Failed\s+[\w.]+\s+\[\d"#, .error, .testFailure), // dotnet test
        p(#"^Test Case '.+' passed"#, .info),

        // Tool errors with a clear subject.
        p(#"^(?:xcodebuild|xcrun|xcode-select|swift-build|swift-test|swift-package|dotnet|make|gmake|ldid|dpkg-deb|codesign|security|simctl|devicectl): (?:error|fatal)"#, .error, .tool),
        p(#"^(?:\S+: )?(?:line \d+: )?\S+: (?:command not found|No such file or directory)$"#, .error, .tool),
        p(#"^(?:sh|bash|zsh|/bin/sh|/bin/bash|/bin/zsh): .*(?:command not found|not found|No such file or directory|Permission denied)"#, .error, .tool),
        p(#"^make(?:\[\d+\])?: \*\*\* No (?:rule|targets)"#, .error, .tool),
        p(#"^==> (?:Error|ERROR):"#, .error, .tool),       // Theos
        p(#"^==> (?:Warning|WARNING):"#, .warning),
        p(#"^fatal: "#, .error, .tool),                       // git
        p(#"^error: "#, .error, .tool),                       // swift, SPM, xcodebuild, cargo
        p(#"^Error: "#, .error, .tool),
        p(#"^warning: "#, .warning),
        p(#"^Traceback \(most recent call last\):"#, .error, .tool),
        p(#"^npm ERR! "#, .error, .tool),

        // Follow-on summaries: true, but never the first thing to show.
        p(#"^\*\* (?:BUILD|ARCHIVE|TEST|CLEAN|ANALYZE|INSTALL) FAILED \*\*"#, .error, .summary),
        p(#"^\*\* (?:BUILD|ARCHIVE|TEST|CLEAN|ANALYZE|INSTALL) (?:SUCCEEDED|INTERRUPTED) \*\*"#, .notice),
        p(#"^The following build commands failed:"#, .error, .summary),
        p(#"^Command .+ failed with a nonzero exit code"#, .error, .summary),
        p(#"^make(?:\[\d+\])?: \*\*\* .*Error \d+"#, .error, .summary),
        p(#"^Build FAILED\.?$"#, .error, .summary),
        p(#"^error: (?:fatalError|Exited with status)"#, .error, .summary),
    ]

    public static func classify(_ line: String) -> LineClassification {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .plain }
        // HCG Terminal's own job header (the command echo, PATH, exit) is context, not output.
        if line.hasPrefix("[hcg] ") { return LineClassification(severity: .notice) }
        // Cheap pre-filter: most lines mention none of these.
        let lower = trimmed.lowercased()
        let interesting = ["error", "warning", "fail", "note:", "undefined", "ld:", "not found", "denied", "fatal", "traceback", "err!", "==>", "*** ", "code sign", "codesign", "provision", "✘"]
        guard interesting.contains(where: { lower.contains($0) }) else { return .plain }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for pattern in patterns where pattern.regex.firstMatch(in: trimmed, range: range) != nil {
            return pattern.result
        }
        return .plain
    }
}

/// The first failure that explains a run, with the lines around it.
public struct FailureContext: Sendable, Equatable {
    /// Index of the failing line in the lines given.
    public var lineIndex: Int
    public var line: String
    public var kind: FailureKind
    /// Up to `context` lines before and after, exactly as logged (already redacted).
    public var before: [String]
    public var after: [String]
    /// True when only a generic summary (for example "** BUILD FAILED **") was found.
    public var isSummaryOnly: Bool { kind == .summary }

    public init(lineIndex: Int, line: String, kind: FailureKind, before: [String], after: [String]) {
        self.lineIndex = lineIndex
        self.line = line
        self.kind = kind
        self.before = before
        self.after = after
    }
}

public enum FailureLocator {
    /// The earliest specific failure; a summary line only when nothing specific exists.
    public static func firstFailure(in lines: [String], context: Int = 4) -> FailureContext? {
        var firstSummary: (Int, FailureKind)?
        for (index, line) in lines.enumerated() {
            let classification = LogClassifier.classify(line)
            guard classification.severity == .error, let kind = classification.failure else { continue }
            if kind == .summary {
                if firstSummary == nil { firstSummary = (index, kind) }
                continue
            }
            return make(lines, index, kind, context)
        }
        if let (index, kind) = firstSummary { return make(lines, index, kind, context) }
        return nil
    }

    private static func make(_ lines: [String], _ index: Int, _ kind: FailureKind, _ context: Int) -> FailureContext {
        let start = max(0, index - context)
        let end = min(lines.count, index + context + 1)
        return FailureContext(
            lineIndex: index, line: lines[index], kind: kind,
            before: Array(lines[start..<index]), after: Array(lines[(index + 1)..<end])
        )
    }
}
