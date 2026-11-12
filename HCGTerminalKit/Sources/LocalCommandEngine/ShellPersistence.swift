import FileWorkspace
import Foundation

/// State shared by all built-in sessions and kept across app launches, stored inside the
/// workspace: command history in `/home/.hcg_history`, the last working directory in
/// `/home/.hcg_cwd`. Plain text, so it can be inspected or deleted from the Files app.
public final class ShellPersistence: @unchecked Sendable {
    public static let historyPath = WorkspacePath.home.appending(".hcg_history")
    public static let directoryPath = WorkspacePath.home.appending(".hcg_cwd")
    public static let historyLimit = 1000

    private let workspace: FileWorkspace
    private let lock = NSLock()

    public init(workspace: FileWorkspace) {
        self.workspace = workspace
    }

    public func loadHistory() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? workspace.readText(Self.historyPath) else { return [] }
        return Array(text.split(separator: "\n").map(String.init).suffix(Self.historyLimit))
    }

    public func appendHistory(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return }
        lock.lock(); defer { lock.unlock() }
        try? workspace.write(trimmed + "\n", to: Self.historyPath, append: true)
        // Keep the file bounded.
        if let text = try? workspace.readText(Self.historyPath) {
            let lines = text.split(separator: "\n")
            if lines.count > Self.historyLimit + 200 {
                try? workspace.write(lines.suffix(Self.historyLimit).joined(separator: "\n") + "\n", to: Self.historyPath)
            }
        }
    }

    public func clearHistory() {
        lock.lock(); defer { lock.unlock() }
        try? workspace.write("", to: Self.historyPath)
    }

    /// The directory the last session was in, if it still exists.
    public func lastDirectory() -> WorkspacePath? {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? workspace.readText(Self.directoryPath),
              let path = try? WorkspacePath(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              workspace.isDirectory(path) else { return nil }
        return path
    }

    public func saveDirectory(_ path: WorkspacePath) {
        lock.lock(); defer { lock.unlock() }
        try? workspace.write(path.string, to: Self.directoryPath)
    }
}

/// Escaping rules shared by completion and the parser.
public enum ShellEscaping {
    /// Characters that must be escaped in an unquoted word.
    static let special: Set<Character> = [" ", "\t", "'", "\"", "\\", "$", "&", ";", "|", "<", ">", "(", ")", "*", "?", "[", "]", "#", "`"]

    /// Backslash-escapes `text` so the parser reads it back as one literal word.
    public static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if special.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// The word the cursor is in (from the last unquoted, unescaped blank), whether it is the
    /// first word of its command, and the quote it is inside, if any.
    public static func currentWord(_ prefix: String) -> (word: String, isCommand: Bool, quote: Character?) {
        var wordStart = prefix.startIndex
        var quote: Character?
        var escaped = false
        var sawCommand = false
        var index = prefix.startIndex
        while index < prefix.endIndex {
            let character = prefix[index]
            if escaped {
                escaped = false
            } else if let open = quote {
                if character == open { quote = nil }
                if character == "\\" && open == "\"" { escaped = true }
            } else if character == "\\" {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == " " || character == "\t" {
                if prefix[wordStart..<index].contains(where: { !$0.isWhitespace }) { sawCommand = true }
                wordStart = prefix.index(after: index)
            } else if ";|&".contains(character) {
                sawCommand = false
                wordStart = prefix.index(after: index)
            }
            index = prefix.index(after: index)
        }
        return (String(prefix[wordStart...]), !sawCommand, quote)
    }

    /// Removes quotes and escapes from a (possibly unfinished) word.
    public static func unescape(_ word: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in word {
            if escaped { result.append(character); escaped = false; continue }
            if let open = quote {
                if character == open { quote = nil } else if character == "\\" && open == "\"" { escaped = true } else { result.append(character) }
            } else if character == "\\" {
                escaped = true
            } else if character == "'" || character == "\"" {
                quote = character
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// Hints shown after a command that is not an HCG built-in.
public enum CommandSuggestions {
    static let remoteTools: Set<String> = [
        "git", "swift", "swiftc", "xcodebuild", "xcrun", "python", "python3", "node", "npm", "make", "cc", "clang",
        "gcc", "dotnet", "ruby", "perl", "brew", "curl", "wget", "ssh", "scp", "rsync", "top", "ps", "kill", "sudo",
        "apt", "apt-get", "bash", "zsh", "sh", "claude", "docker", "go", "cargo", "java",
    ]
    static let editors: Set<String> = ["vi", "vim", "nano", "emacs", "ed", "open", "edit"]

    public static func hints(for name: String, registry: BuiltinRegistry) -> [String] {
        var hints: [String] = []
        let close = registry.sortedNames
            .map { ($0, distance($0, name)) }
            .filter { $0.1 <= (name.count <= 3 ? 1 : 2) && $0.1 > 0 }
            .sorted { $0.1 < $1.1 }
            .prefix(2)
            .map(\.0)
        if !close.isEmpty { hints.append("Did you mean: \(close.joined(separator: ", "))?") }
        if editors.contains(name) {
            hints.append("To edit a file, open Files in the sidebar and tap the file.")
        } else if remoteTools.contains(name) {
            hints.append("\(name) is a system program. Run it in a Remote Host session (sidebar → New Session → Remote Host Session).")
        }
        hints.append("Type `help` for the built-in commands.")
        return hints
    }

    /// Levenshtein distance (small inputs only).
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
