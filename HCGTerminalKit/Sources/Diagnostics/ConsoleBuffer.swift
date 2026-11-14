import Foundation

/// Which tool produced a console line.
public enum ConsoleSource: String, Codable, Sendable, CaseIterable {
    case doctor = "Doctor"
    case build = "Build"
    case install = "Install"
    case app = "App"

    public var label: String { rawValue }
}

/// One line in the Log Console. The text is redacted before the line is created.
public struct ConsoleLine: Codable, Sendable, Identifiable, Hashable {
    /// Increasing sequence number; also the identity.
    public var id: Int
    public var date: Date
    public var source: ConsoleSource
    /// Where the output came from, e.g. "This device" or "Build Mac (mac.local)".
    public var host: String
    /// The job the line belongs to (a build job ID or a Doctor run ID).
    public var job: String?
    public var severity: ConsoleSeverity
    public var failure: FailureKind?
    public var text: String
}

/// A bounded in-memory console. Old lines are dropped first; the full log of a build stays in
/// its log file, so dropping display lines never loses the record. Redaction happens before a
/// line is stored here, so nothing kept or exported contains a recognised secret.
public struct ConsoleBuffer: Sendable {
    public private(set) var lines: [ConsoleLine] = []
    public private(set) var droppedCount = 0
    public let capacity: Int
    private var nextID = 0
    private var redactor: SecretRedactor
    private var pemStates: [String: SecretRedactor.PEMState] = [:]
    /// The first specific failure for each job, kept even after its lines scroll out.
    public private(set) var firstFailures: [String: ConsoleLine] = [:]

    public init(capacity: Int = 20_000, redactor: SecretRedactor = SecretRedactor()) {
        self.capacity = max(100, capacity)
        self.redactor = redactor
    }

    public mutating func setRedactor(_ redactor: SecretRedactor) { self.redactor = redactor }

    /// Appends complete lines (already split; see `LineAssembler`). Returns the stored lines.
    @discardableResult
    public mutating func append(_ rawLines: [String], source: ConsoleSource, host: String, job: String?, date: Date = Date(), severity: ConsoleSeverity? = nil) -> [ConsoleLine] {
        var added: [ConsoleLine] = []
        let stateKey = "\(source.rawValue)|\(host)|\(job ?? "")"
        var pem = pemStates[stateKey] ?? SecretRedactor.PEMState()
        for raw in rawLines {
            let text = pem.process(raw, redactor: redactor)
            let classification = LogClassifier.classify(text)
            let line = ConsoleLine(
                id: nextID, date: date, source: source, host: host, job: job,
                severity: severity ?? classification.severity, failure: severity == nil ? classification.failure : nil, text: text
            )
            nextID += 1
            lines.append(line)
            added.append(line)
            if let job, line.severity == .error, let failure = line.failure {
                // Keep the first specific failure; a summary only until something specific appears.
                if let existing = firstFailures[job] {
                    if existing.failure == .summary, failure != .summary { firstFailures[job] = line }
                } else {
                    firstFailures[job] = line
                }
            }
        }
        pemStates[stateKey] = pem
        if lines.count > capacity {
            let excess = lines.count - capacity
            lines.removeFirst(excess)
            droppedCount += excess
        }
        return added
    }

    public mutating func clear() {
        lines.removeAll()
        droppedCount = 0
        firstFailures.removeAll()
        pemStates.removeAll()
    }

    /// Lines matching the filters. `search` is case-insensitive.
    public func filtered(search: String = "", minimumSeverity: ConsoleSeverity = .debug, sources: Set<ConsoleSource>? = nil, job: String? = nil) -> [ConsoleLine] {
        lines.filter { line in
            line.severity >= minimumSeverity
                && (sources?.contains(line.source) ?? true)
                && (job == nil || line.job == job)
                && (search.isEmpty || line.text.localizedCaseInsensitiveContains(search))
        }
    }

    /// Plain-text export with timestamps, host and job labels. Text is already redacted.
    public static func export(_ lines: [ConsoleLine]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return lines.map { line in
            let job = line.job.map { " \($0)" } ?? ""
            return "\(formatter.string(from: line.date)) [\(line.source.label) · \(line.host)\(job)] \(line.severity.label.uppercased()): \(line.text)"
        }.joined(separator: "\n")
    }
}
