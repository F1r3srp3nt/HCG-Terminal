import Foundation

/// `hcg.diagnostic-report/1`: a redacted diagnostic report shared between
/// paired installations. A report is DATA. Viewers render every field as
/// plain text; nothing in a report is ever executed, opened or interpreted.
public struct DiagnosticReport: Codable, Sendable, Equatable {
    public struct Origin: Codable, Sendable, Equatable {
        public var app: String
        public var appVersion: String
        public var installationId: String
        public var deviceName: String
        public var module: String?
        public var moduleVersion: String?

        public init(app: String, appVersion: String, installationId: String, deviceName: String, module: String? = nil, moduleVersion: String? = nil) {
            self.app = app
            self.appVersion = appVersion
            self.installationId = installationId
            self.deviceName = deviceName
            self.module = module
            self.moduleVersion = moduleVersion
        }
    }

    public struct Redaction: Codable, Sendable, Equatable {
        public var policy: String
        public var applied: Bool
    }

    public struct Summary: Codable, Sendable, Equatable {
        public var status: String
        public var highestSeverity: String?
        public var findingCount: Int

        public init(status: String, highestSeverity: String?, findingCount: Int) {
            self.status = status
            self.highestSeverity = highestSeverity
            self.findingCount = findingCount
        }
    }

    public struct Finding: Codable, Sendable, Equatable {
        public var title: String
        public var severity: String?
        public var confidence: String?
        public var basis: String?
        public var location: String?
        public var evidence: [String]
        public var explanation: String?
        public var remediation: String?

        public init(title: String, severity: String?, confidence: String?, basis: String?, location: String?, evidence: [String],
                    explanation: String?, remediation: String?) {
            self.title = title
            self.severity = severity
            self.confidence = confidence
            self.basis = basis
            self.location = location
            self.evidence = evidence
            self.explanation = explanation
            self.remediation = remediation
        }
    }

    public struct Check: Codable, Sendable, Equatable {
        public var title: String
        public var outcome: String
        public var detail: String?

        public init(title: String, outcome: String, detail: String?) {
            self.title = title
            self.outcome = outcome
            self.detail = detail
        }
    }

    public var schema: String
    public var reportId: String
    public var kind: String
    public var title: String
    public var origin: Origin
    public var createdAt: Date
    public var completedAt: Date?
    public var sharedAt: Date?
    public var redaction: Redaction
    public var summary: Summary
    public var scope: [String]
    public var findings: [Finding]
    public var checks: [Check]
    public var limitations: [String]
    public var notTested: [String]

    /// Builds a report and redacts every string with `redactor` (the sender's job).
    public static func make(reportId: String, kind: String, title: String, origin: Origin, createdAt: Date, completedAt: Date?,
                            summary: Summary, scope: [String], findings: [Finding], checks: [Check], limitations: [String],
                            notTested: [String], redactor: ReportRedactor = .standard, sharedAt: Date = Date()) -> DiagnosticReport {
        let r = redactor
        return DiagnosticReport(
            schema: DeviceLinkProtocol.reportSchema, reportId: reportId.lowercased(), kind: kind, title: r.redact(title), origin: origin,
            createdAt: createdAt, completedAt: completedAt, sharedAt: sharedAt,
            redaction: Redaction(policy: DeviceLinkProtocol.redactionPolicy, applied: true), summary: summary,
            scope: scope.map(r.redact),
            findings: findings.map { f in
                Finding(title: r.redact(f.title), severity: f.severity, confidence: f.confidence, basis: f.basis,
                        location: f.location.map(r.redact), evidence: f.evidence.map(r.redact),
                        explanation: f.explanation.map(r.redact), remediation: f.remediation.map(r.redact))
            },
            checks: checks.map { Check(title: r.redact($0.title), outcome: $0.outcome, detail: $0.detail.map(r.redact)) },
            limitations: limitations.map(r.redact), notTested: notTested.map(r.redact))
    }

    public func encoded() throws -> Data { try LinkJSON.encoder().encode(self) }

    public static func decode(_ data: Data) throws -> DiagnosticReport { try LinkJSON.decoder().decode(DiagnosticReport.self, from: data) }
}

/// `hcg.redaction/1`: the sender-side redaction rules. Apps apply their own
/// redactor first (Sentinel's `Redactor`), then this one; HCG Server refuses a
/// report in which its own scan still finds a credential.
public struct ReportRedactor: Sendable {
    public static let placeholder = "[REDACTED]"
    public static let standard = ReportRedactor(maskNetworkIdentifiers: false)
    /// Also masks e-mail addresses, IP and MAC addresses (e.g. Wi-Fi BSSID, gateway).
    public static let strict = ReportRedactor(maskNetworkIdentifiers: true)

    public var maskNetworkIdentifiers: Bool

    private static let rules: [(NSRegularExpression, String)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#, "[REDACTED PRIVATE KEY]"),
        (#"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, placeholder),
        // A credential after an auth scheme contains a digit or base64 punctuation ("Basic connectivity" is prose).
        (#"(?i)\b(bearer|basic|digest|negotiate)\s+(?=[A-Za-z0-9._~+/=-]*[0-9+/=])[A-Za-z0-9._~+/=-]{6,}"#, "$1 " + placeholder),
        (#"([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s:@\[\]]+:[^/\s@\[\]]+@"#, "$1" + placeholder + "@"),
        (#"(?i)("?(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|client[_-]?secret|authorization|cookie|session)"?\s*[:=]\s*"?)(?!\[REDACTED)(?!(?i:bearer|basic|digest|negotiate)\b)[^"\s&,;]+"#, "$1" + placeholder),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static let networkRules: [(NSRegularExpression, String)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[REDACTED EMAIL]"),
        (#"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#, "[REDACTED MAC]"),
        (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[REDACTED IP]"),
        (#"\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}\b"#, "[REDACTED IP]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public init(maskNetworkIdentifiers: Bool) { self.maskNetworkIdentifiers = maskNetworkIdentifiers }

    public func redact(_ s: String) -> String {
        var out = s
        for (re, template) in Self.rules + (maskNetworkIdentifiers ? Self.networkRules : []) {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}

/// The checks HCG Server runs on a shared report, run locally first so the
/// user gets the reason before anything leaves the device.
public enum ReportValidator {
    public static let maxBytes = 256 * 1024

    private static let forbidden: [(NSRegularExpression, String)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, "a private key block"),
        (#"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, "a JWT-shaped token"),
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{8,}"#, "a bearer token"),
        (#"[a-zA-Z][a-zA-Z0-9+.-]*://[^/\s:@\[\]]+:[^/\s@\[\]]+@"#, "a URL with a user name and password"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Problems that would make the server refuse the report (empty = OK).
    public static func problems(_ report: DiagnosticReport, encoded: Data) -> [String] {
        var out: [String] = []
        if report.schema != DeviceLinkProtocol.reportSchema { out.append("unsupported report schema") }
        if !report.redaction.applied || report.redaction.policy != DeviceLinkProtocol.redactionPolicy { out.append("report is not marked redacted") }
        if report.title.isEmpty || report.title.count > 200 { out.append("title must be 1–200 characters") }
        if encoded.count > maxBytes { out.append("report is larger than 256 KiB") }
        let text = String(decoding: encoded, as: UTF8.self)
        for (re, what) in forbidden where re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            out.append("the report still contains \(what)")
        }
        return out
    }
}

/// Plain-text presentation for viewers. Produces labelled lines only; never
/// links, Markdown, HTML or commands.
public enum ReportTextRenderer {
    public struct Section: Sendable, Equatable {
        public var title: String
        public var lines: [String]
    }

    public static func sections(_ r: DiagnosticReport, timeZone: TimeZone = .current) -> [Section] {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        df.timeZone = timeZone
        var s: [Section] = []
        var overview = [
            "Report: \(r.title)",
            "Kind: \(r.kind)",
            "From: \(r.origin.deviceName) (\(r.origin.app) \(r.origin.appVersion))",
            "Created: \(df.string(from: r.createdAt))",
            "Status: \(r.summary.status)",
            "Findings: \(r.summary.findingCount)" + (r.summary.highestSeverity.map { " (highest: \($0))" } ?? ""),
            "Redaction: \(r.redaction.applied ? "applied by the sender (\(r.redaction.policy))" : "NOT applied")",
        ]
        if let c = r.completedAt { overview.insert("Completed: \(df.string(from: c))", at: 4) }
        if let m = r.origin.module { overview.append("Module: \(m)" + (r.origin.moduleVersion.map { " \($0)" } ?? "")) }
        s.append(Section(title: "Overview", lines: overview))
        if !r.scope.isEmpty { s.append(Section(title: "Scope", lines: r.scope)) }
        for (i, f) in r.findings.enumerated() {
            var lines = ["Severity: \(f.severity ?? "not stated")", "Confidence: \(f.confidence ?? "not stated")"]
            if let b = f.basis { lines.append("Basis: \(b)") }
            if let l = f.location { lines.append("Location: \(l)") }
            lines += f.evidence.map { "Evidence: \($0)" }
            if let e = f.explanation { lines.append("Explanation: \(e)") }
            if let rem = f.remediation { lines.append("Remediation: \(rem)") }
            s.append(Section(title: "Finding \(i + 1): \(f.title)", lines: lines))
        }
        if !r.checks.isEmpty {
            s.append(Section(title: "Checks", lines: r.checks.map { "\($0.title): \($0.outcome)" + ($0.detail.map { " — \($0)" } ?? "") }))
        }
        if !r.limitations.isEmpty { s.append(Section(title: "Limitations", lines: r.limitations)) }
        if !r.notTested.isEmpty { s.append(Section(title: "Not tested", lines: r.notTested)) }
        return s
    }

    /// The whole report as plain text (for copying).
    public static func text(_ r: DiagnosticReport) -> String {
        sections(r).map { ([$0.title.uppercased()] + $0.lines).joined(separator: "\n") }.joined(separator: "\n\n")
    }
}
