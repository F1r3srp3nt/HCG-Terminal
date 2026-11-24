import Foundation

/// A read-only diagnostic report made of sections of findings. Used by the Unleashed jailbreak
/// diagnostics; nothing in a report has been changed on the device.
public struct DiagnosticReport: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public enum Status: String, Sendable, Equatable {
            /// Checked and as expected.
            case ok
            /// Checked; worth attention.
            case warning
            /// Checked; something is wrong or missing.
            case problem
            /// Information only (no judgement).
            case info
            /// Could not be checked (for example the location is not readable).
            case unknown
        }

        public var id: String
        public var title: String
        public var status: Status
        public var detail: String
        /// Paths, values or lines that support the finding.
        public var evidence: [String]

        public init(id: String, title: String, status: Status, detail: String, evidence: [String] = []) {
            self.id = id
            self.title = title
            self.status = status
            self.detail = detail
            self.evidence = evidence
        }
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var items: [Item]
        /// Plain guidance for the user, never an action HCG Terminal takes.
        public var footer: String?

        public init(id: String, title: String, items: [Item], footer: String? = nil) {
            self.id = id
            self.title = title
            self.items = items
            self.footer = footer
        }
    }

    public var sections: [Section]
    public var generatedAt: Date

    public init(sections: [Section], generatedAt: Date = Date()) {
        self.sections = sections
        self.generatedAt = generatedAt
    }

    /// Plain-text export for sharing or support.
    public var text: String {
        var lines = ["HCG Terminal Unleashed diagnostics, \(ISO8601DateFormatter().string(from: generatedAt))"]
        for section in sections {
            lines.append("")
            lines.append("## \(section.title)")
            for item in section.items {
                lines.append("[\(item.status.rawValue.uppercased())] \(item.title): \(item.detail)")
                lines += item.evidence.map { "    \($0)" }
            }
            if let footer = section.footer { lines.append("  \(footer)") }
        }
        return lines.joined(separator: "\n")
    }
}
