import Foundation
import TerminalCore

/// What to do when an imported or saved item already exists.
public enum ConflictPolicy: String, Sendable, CaseIterable {
    /// Replace the existing item.
    case replace
    /// Keep both: the new item gets a free name such as "report 2.txt".
    case keepBoth
    /// Leave the existing item and skip this one.
    case skip
    /// Refuse (the caller asks the user first).
    case fail
}

public enum ImportOutcome: Hashable, Sendable {
    case imported(WorkspacePath)
    case replaced(WorkspacePath)
    case keptBoth(WorkspacePath)
    case skipped(String)
}

/// A text file opened for editing, with what is needed to detect later changes on disk.
public struct TextDocument: Hashable, Sendable {
    public var path: WorkspacePath
    public var text: String
    public var modified: Date?
    public var size: Int64
}

public enum DocumentError: Error, LocalizedError, Equatable {
    case notText(String)
    case tooLarge(String, Int64, limit: Int64)
    case changedOnDisk(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .notText(let path): "\(path) is not a UTF-8 text file, so it cannot be edited here."
        case .tooLarge(let path, let size, let limit):
            "\(path) is \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)); the editor opens files up to \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))."
        case .changedOnDisk(let path): "\(path) was changed by something else since you opened it."
        case .conflict(let name): "“\(name)” already exists here."
        }
    }
}

public extension FileWorkspace {
    static let editableTextLimit: Int64 = 2 * 1024 * 1024

    /// A name not yet used in `directory`: "report.txt" → "report 2.txt", "report 3.txt", …
    func uniqueName(for name: String, in directory: WorkspacePath) -> String {
        guard exists(directory.appending(name)) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !exists(directory.appending(candidate)) { return candidate }
            counter += 1
        }
    }

    /// Names among `urls` that already exist in `directory` (to ask the user once).
    func conflicts(importing urls: [URL], into directory: WorkspacePath) -> [String] {
        urls.map(\.lastPathComponent).filter { exists(directory.appending($0)) }
    }

    /// Copies a file or folder from outside the workspace (e.g. the Files app) into `directory`.
    /// Refused while “Files you choose” is turned off.
    func importItem(from source: URL, into directory: WorkspacePath, policy: ConflictPolicy, access: AccessPolicy = .shared) throws -> ImportOutcome {
        try access.require(.externalFiles)
        guard isDirectory(directory) else { throw WorkspaceError.notADirectory(directory.string) }
        let name = source.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw WorkspaceError.invalidName(name) }
        #if canImport(Darwin)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        #endif
        var destination = directory.appending(name)
        var outcome = ImportOutcome.imported(destination)
        if exists(destination) {
            switch policy {
            case .fail: throw DocumentError.conflict(name)
            case .skip: return .skipped(name)
            case .replace:
                try remove(destination, recursive: true)
                outcome = .replaced(destination)
            case .keepBoth:
                destination = directory.appending(uniqueName(for: name, in: directory))
                outcome = .keptBoth(destination)
            }
        }
        try FileManager.default.copyItem(at: source, to: url(for: destination))
        return outcome
    }

    /// The file URL handed to the system export sheet. Refused while “Files you choose” is off.
    func exportURL(for path: WorkspacePath, access: AccessPolicy = .shared) throws -> URL {
        try access.require(.externalFiles)
        return try url(for: path)
    }

    func rename(_ path: WorkspacePath, to newName: String) throws -> WorkspacePath {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains("\0") else {
            throw WorkspaceError.invalidName(newName)
        }
        let destination = path.parent.appending(trimmed)
        guard destination != path else { return path }
        guard !exists(destination) else { throw DocumentError.conflict(trimmed) }
        try move(path, to: destination)
        return destination
    }

    func openTextDocument(_ path: WorkspacePath) throws -> TextDocument {
        let info = try item(at: path)
        guard !info.isDirectory else { throw WorkspaceError.isADirectory(path.string) }
        guard info.size <= Self.editableTextLimit else { throw DocumentError.tooLarge(path.string, info.size, limit: Self.editableTextLimit) }
        let data = try readData(path, limit: Int(Self.editableTextLimit))
        guard let text = String(data: data, encoding: .utf8), !data.contains(0) else { throw DocumentError.notText(path.string) }
        return TextDocument(path: path, text: text, modified: info.modified, size: info.size)
    }

    /// Saves `text`. If the file changed on disk since `document` was opened, throws
    /// `.changedOnDisk` unless `overwriteChanges` is true. Returns the refreshed document.
    @discardableResult
    func saveTextDocument(_ document: TextDocument, text: String, overwriteChanges: Bool = false) throws -> TextDocument {
        if exists(document.path), !overwriteChanges {
            let current = try item(at: document.path)
            if current.modified != document.modified || current.size != document.size {
                throw DocumentError.changedOnDisk(document.path.string)
            }
        }
        try write(Data(text.utf8), to: document.path)
        let saved = try item(at: document.path)
        return TextDocument(path: document.path, text: text, modified: saved.modified, size: saved.size)
    }

    /// Creates an empty file or folder with a free name based on `name`.
    func createItem(named name: String, in directory: WorkspacePath, directory makeDirectory: Bool) throws -> WorkspacePath {
        let path = directory.appending(uniqueName(for: name, in: directory))
        if makeDirectory { try createDirectory(path) } else { try write(Data(), to: path) }
        return path
    }
}
