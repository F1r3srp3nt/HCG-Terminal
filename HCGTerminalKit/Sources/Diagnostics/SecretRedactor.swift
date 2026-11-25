import Foundation

/// Removes credentials and tokens from log text before it is stored, shown or exported.
///
/// Applied line by line (a secret split across two network chunks is joined first by
/// `LineAssembler`). Patterns are deliberately specific: redaction replaces only the secret part,
/// so the surrounding text (which command failed, which host) stays readable. Exact secrets known
/// to the app (for example a password typed for this host) can be added with `adding(_:)`.
public struct SecretRedactor: Sendable {
    public static let marker = "[REDACTED]"

    struct Rule: Sendable {
        let regex: NSRegularExpression
        /// Capture group that holds the secret; 0 replaces the whole match.
        let group: Int
    }

    private let rules: [Rule]
    private let literals: [String]

    public init(literals: [String] = []) {
        self.rules = Self.defaultRules
        // Very short values would redact ordinary words; the minimum keeps redaction meaningful.
        self.literals = literals.filter { $0.count >= 6 }.sorted { $0.count > $1.count }
    }

    /// A redactor that also removes these exact values (passwords, tokens known to the app).
    public func adding(_ secrets: [String]) -> SecretRedactor {
        SecretRedactor(literals: literals + secrets)
    }

    static let defaultRules: [Rule] = {
        func rule(_ pattern: String, group: Int = 0, options: NSRegularExpression.Options = []) -> Rule {
            Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), group: group)
        }
        return [
            // PEM private-key header lines and their base64 body lines are handled by `PEMState`;
            // a single-line key (as in JSON) is caught here.
            rule(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[A-Za-z0-9+/=\\n\s]*-----END [A-Z0-9 ]*PRIVATE KEY-----"#),
            // HTTP authorization headers.
            rule(#"(?i)\b(authorization|proxy-authorization)\s*[:=]\s*(?:bearer|basic|token|digest)?\s*([^\s"',;]+)"#, group: 2),
            rule(#"(?i)\bbearer\s+([A-Za-z0-9\-._~+/]{12,}=*)"#, group: 1),
            // URL user info: https://user:secret@host
            rule(#"(?i)\b[a-z][a-z0-9+.\-]*://[^/\s:@]+:([^/\s@]+)@"#, group: 1),
            // key=value / key: value / "key": "value" for secret-looking keys.
            rule(#"(?i)\b((?:[a-z0-9]+[_\-.])*(?:password|passwd|pwd|secret|token|api[_\-]?key|apikey|access[_\-]?key|private[_\-]?key|client[_\-]?secret|auth[_\-]?token|session[_\-]?id|credentials?))["']?\s*[:=]\s*["']?([^\s"',;&]{4,})"#, group: 2),
            // Command-line flags: --password x, --token=x, -p:Password=x (msbuild).
            rule(#"(?i)(?:--?(?:password|passphrase|token|api-key|apikey|secret|auth)(?:[=\s]+))([^\s"']{4,})"#, group: 1),
            rule(#"(?i)/p:(?:[a-z]*password|[a-z]*token|[a-z]*secret)=([^\s"';]+)"#, group: 1),
            // Well-known token formats.
            rule(#"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#),
            rule(#"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#),
            rule(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
            rule(#"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#),
            rule(#"\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}\b"#),
            rule(#"\bglpat-[A-Za-z0-9_\-]{20,}\b"#),
            rule(#"\bnpm_[A-Za-z0-9]{36}\b"#),
            rule(#"\bAIza[0-9A-Za-z_\-]{35}\b"#),
            // JSON Web Tokens (three base64url parts, header starts with {").
            rule(#"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#),
        ]
    }()

    /// Redacts one line (no trailing newline required).
    public func redact(_ line: String) -> String {
        var text = line
        for literal in literals where text.contains(literal) {
            text = text.replacingOccurrences(of: literal, with: Self.marker)
        }
        for rule in rules {
            let range = NSRange(text.startIndex..., in: text)
            let matches = rule.regex.matches(in: text, range: range)
            guard !matches.isEmpty else { continue }
            // Replace from the end so earlier ranges stay valid.
            for match in matches.reversed() {
                let target = match.range(at: rule.group)
                guard target.location != NSNotFound, let swiftRange = Range(target, in: text) else { continue }
                if text[swiftRange] == Self.marker { continue }
                text.replaceSubrange(swiftRange, with: Self.marker)
            }
        }
        return text
    }

    /// Redacts multi-line text, including PEM private-key blocks.
    public func redactText(_ text: String) -> String {
        var state = PEMState()
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { state.process(String($0), redactor: self) }
            .joined(separator: "\n")
    }

    /// Tracks whether the current line is inside a PEM private-key block.
    public struct PEMState: Sendable {
        var inside = false
        public init() {}

        public mutating func process(_ line: String, redactor: SecretRedactor) -> String {
            if line.contains("-----BEGIN"), line.contains("PRIVATE KEY-----"), !line.contains("-----END") {
                inside = true
                return line
            }
            if inside {
                if line.contains("-----END") { inside = false; return line }
                return SecretRedactor.marker
            }
            return redactor.redact(line)
        }
    }
}

/// Joins streamed chunks into complete lines, so a line (and any secret in it) is redacted and
/// classified whole. Carriage-return progress updates collapse to their final state.
public struct LineAssembler: Sendable {
    private var pending = ""
    public init() {}

    /// Appends a chunk and returns the lines it completed.
    public mutating func append(_ chunk: String) -> [String] {
        pending += chunk
        var lines: [String] = []
        while let newline = pending.firstIndex(of: "\n") {
            var line = String(pending[..<newline])
            pending.removeSubrange(...newline)
            if line.hasSuffix("\r") { line.removeLast() }
            if let lastCR = line.lastIndex(of: "\r") { line = String(line[line.index(after: lastCR)...]) }
            lines.append(line)
        }
        // A single line without a newline must not grow without bound.
        if pending.utf8.count > 64 * 1024 {
            lines.append(pending)
            pending = ""
        }
        return lines
    }

    /// The unterminated rest, at the end of a stream.
    public mutating func flush() -> [String] {
        defer { pending = "" }
        return pending.isEmpty ? [] : [pending]
    }
}
