import DeveloperWorkspace
import FileWorkspace
import Foundation
import Observation
import RemoteSSH
import TerminalCore

/// One running or finished transfer, shown at the top of Remote Files.
@MainActor
@Observable
public final class RemoteTransfer: Identifiable {
    public enum Direction: Sendable { case download, upload }
    public enum State: Equatable {
        case running
        case finished(String)
        case failed(String)
        case cancelled
    }

    public let id = UUID()
    public let direction: Direction
    public let name: String
    public private(set) var done: UInt64 = 0
    public private(set) var total: UInt64?
    public internal(set) var state: State = .running
    @ObservationIgnored var task: Task<Void, Never>?

    init(direction: Direction, name: String, total: UInt64?) {
        self.direction = direction
        self.name = name
        self.total = total
    }

    /// 0…1 when the size is known.
    public var fraction: Double? {
        guard let total, total > 0 else { return total == 0 ? 1 : nil }
        return min(1, Double(done) / Double(total))
    }

    func update(_ done: UInt64, _ total: UInt64?) {
        self.done = done
        if let total { self.total = total }
    }

    public func cancel() { task?.cancel() }
}

/// SFTP browsing and transfers for one host. Downloads go to the workspace under
/// `downloads/<host>`; uploads come from the workspace. Uses the host's existing SSH connection
/// (and its host-key and access checks); nothing is sent before the user acts.
@MainActor
@Observable
public final class RemoteFilesModel {
    public let host: HostProfile
    @ObservationIgnored private let app: TerminalAppModel
    @ObservationIgnored private var client: SFTPClient?

    public private(set) var path: String = ""
    public private(set) var entries: [SFTPEntry] = []
    public private(set) var loading = false
    public private(set) var errorMessage: String?
    public private(set) var transfers: [RemoteTransfer] = []

    public init(host: HostProfile, app: TerminalAppModel) {
        self.host = host
        self.app = app
    }

    /// Workspace folder for this host's downloads, e.g. `downloads/Build Mac`.
    public var downloadFolder: WorkspacePath {
        WorkspacePath(components: ["downloads", Self.safeName(host.name)])
    }

    public var canGoUp: Bool { !path.isEmpty && path != "/" }

    // MARK: Browsing

    /// Opens SFTP (connecting if needed) and lists the start folder: the host's projects folder
    /// when set, otherwise the login folder.
    public func start() async {
        guard client == nil else { return await reload() }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let connection = try await app.connection(for: host)
            let client = try await SFTPClient.open(on: connection)
            self.client = client
            let start = host.projectsPath.map { $0.replacingOccurrences(of: "~", with: ".") } ?? "."
            if let resolved = try? await client.realpath(start) {
                path = resolved
            } else {
                path = try await client.realpath(".")
            }
            entries = try await client.list(path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func open(_ folder: String) async {
        guard let client else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let resolved = try await client.realpath(folder)
            entries = try await client.list(resolved)
            path = resolved
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func goUp() async { await open(SFTPClient.parent(of: path)) }

    public func reload() async { await open(path.isEmpty ? "." : path) }

    public func stop() async {
        for transfer in transfers where transfer.state == .running { transfer.cancel() }
        await client?.close()
        client = nil
    }

    // MARK: Changes

    public func makeFolder(named name: String) async {
        guard let client, let name = Self.validName(name) else { errorMessage = "Enter a folder name without “/”."; return }
        do {
            try await client.makeDirectory(SFTPClient.join(path, name))
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes a file or an empty folder (the user confirms first).
    public func delete(_ entry: SFTPEntry) async {
        guard let client else { return }
        do {
            try await client.remove(entry.path, isDirectory: entry.isDirectory)
            await reload()
        } catch {
            errorMessage = entry.isDirectory
                ? "\(error.localizedDescription) Only empty folders can be deleted here."
                : error.localizedDescription
        }
    }

    public func clearError() { errorMessage = nil }

    public func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running }
    }

    // MARK: Transfers

    /// Downloads a file into the workspace. Never overwrites: an existing name gets " 2", " 3"…
    @discardableResult
    public func download(_ entry: SFTPEntry) -> RemoteTransfer? {
        guard let client, !entry.isDirectory else { return nil }
        let workspace = app.dependencies.workspace
        let folder = downloadFolder
        let transfer = RemoteTransfer(direction: .download, name: entry.name, total: entry.size)
        transfers.insert(transfer, at: 0)
        transfer.task = Task {
            do {
                try workspace.createDirectory(folder, intermediates: true)
                let existing = Set(((try? workspace.list(folder, includeHidden: true)) ?? []).map(\.name))
                let name = Self.uniqueName(entry.name, existing: existing)
                let destination = try workspace.url(for: folder.appending(name))
                try await client.download(entry.path, to: destination) { done, total in
                    Task { @MainActor in transfer.update(done, total) }
                }
                transfer.state = .finished("Saved to \(folder.appending(name).string)")
            } catch is CancellationError {
                transfer.state = .cancelled
            } catch {
                transfer.state = .failed(error.localizedDescription)
            }
        }
        return transfer
    }

    /// Uploads a workspace file into the current remote folder. `replace` must be confirmed by
    /// the user when a file of that name exists.
    @discardableResult
    public func upload(_ item: WorkspacePath, replace: Bool) -> RemoteTransfer? {
        guard let client, let source = try? app.dependencies.workspace.url(for: item) else { return nil }
        let target = SFTPClient.join(path, item.name)
        let transfer = RemoteTransfer(direction: .upload, name: item.name, total: nil)
        transfers.insert(transfer, at: 0)
        transfer.task = Task { [weak self] in
            do {
                try await client.upload(source, to: target, replace: replace) { done, total in
                    Task { @MainActor in transfer.update(done, total) }
                }
                transfer.state = .finished("Uploaded to \(target)")
                await self?.reload()
            } catch is CancellationError {
                transfer.state = .cancelled
            } catch {
                transfer.state = .failed(error.localizedDescription)
            }
        }
        return transfer
    }

    /// Whether the current folder already has an entry called `name` (as last listed).
    public func exists(_ name: String) -> Bool { entries.contains { $0.name == name } }

    // MARK: Helpers

    /// "report.txt" → "report 2.txt" when taken, and so on.
    nonisolated static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }

    /// Folder-safe version of a host name.
    nonisolated static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "host" : cleaned
    }

    nonisolated static func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else { return nil }
        return trimmed
    }
}
