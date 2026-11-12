import Foundation

/// A user-controlled switch that limits what HCG Terminal itself may do.
///
/// Three things are kept apart everywhere in the app:
/// 1. *Included in this build* — whether the code exists (e.g. the Unleashed backend).
/// 2. *Available to this process on this device* — what detection and real use observed.
/// 3. *Enabled by the user* — this switch.
///
/// A switch only ever restricts. Turning one on never creates a permission, never changes iOS
/// settings and never makes an unavailable capability usable; it only allows HCG Terminal to use
/// access the device already grants. Turning one off does not remove a jailbreak, change
/// system-wide permissions or undo earlier filesystem changes, and it deletes nothing (files,
/// credentials and session history are kept).
public enum AccessControl: String, CaseIterable, Codable, Sendable, Identifiable {
    case workspaceCommands
    case externalFiles
    case unleashedFeatures
    case localShell
    case localhostSSH
    case expandedFileRead
    case expandedFileWrite
    case packageManagement
    case processInspection
    case privilegedOperations
    case remoteSSH
    case remoteBuilds

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .workspaceCommands: "Local workspace commands"
        case .externalFiles: "Files you choose (import/export)"
        case .unleashedFeatures: "Unleashed features"
        case .localShell: "Local shell execution"
        case .localhostSSH: "Localhost SSH fallback"
        case .expandedFileRead: "Expanded filesystem browsing"
        case .expandedFileWrite: "Filesystem modifications"
        case .packageManagement: "Package management"
        case .processInspection: "Process inspection"
        case .privilegedOperations: "Privileged operations"
        case .remoteSSH: "Remote SSH"
        case .remoteBuilds: "Remote builds and tests"
        }
    }

    public var symbolName: String {
        switch self {
        case .workspaceCommands: "terminal"
        case .externalFiles: "doc.badge.arrow.up"
        case .unleashedFeatures: "bolt.shield"
        case .localShell: "apple.terminal"
        case .localhostSSH: "point.3.connected.trianglepath.dotted"
        case .expandedFileRead: "folder"
        case .expandedFileWrite: "square.and.pencil"
        case .packageManagement: "shippingbox"
        case .processInspection: "list.bullet.rectangle"
        case .privilegedOperations: "lock.shield"
        case .remoteSSH: "network"
        case .remoteBuilds: "hammer"
        }
    }

    /// Only meaningful in the Unleashed build (the code is not in the standard build).
    public var requiresUnleashedBackend: Bool {
        switch self {
        case .unleashedFeatures, .localShell, .localhostSSH, .expandedFileRead, .expandedFileWrite, .packageManagement, .privilegedOperations: true
        case .workspaceCommands, .externalFiles, .processInspection, .remoteSSH, .remoteBuilds: false
        }
    }

    /// The factory setting. Expanded filesystem access starts read-only and privileged
    /// operations start off.
    public var defaultEnabled: Bool {
        switch self {
        case .expandedFileWrite, .privilegedOperations: false
        default: true
        }
    }

    /// Switches that must also be on for this one to take effect.
    public var prerequisites: [AccessControl] {
        switch self {
        case .localShell, .localhostSSH, .expandedFileRead, .packageManagement: [.unleashedFeatures]
        case .expandedFileWrite: [.expandedFileRead]
        case .privilegedOperations: [.localShell]
        case .remoteBuilds: [.remoteSSH]
        default: []
        }
    }

    /// Switches that stop working when this one is off.
    public var dependents: [AccessControl] {
        AccessControl.allCases.filter { $0.prerequisites.contains(self) }
    }

    public var whenOn: String {
        switch self {
        case .workspaceCommands:
            "Local Vanilla sessions run HCG's built-in commands (ls, cat, grep, edit, …) on the app's own workspace."
        case .externalFiles:
            "You can import files you pick in the Files app into the workspace and export workspace files. HCG Terminal only sees the items you pick."
        case .unleashedFeatures:
            "HCG Terminal may use the Unleashed backend on this device: the switches below decide which parts. It does not grant any permission the device does not already give this app."
        case .localShell:
            "Unleashed may start a shell in a pseudo-terminal and launch installed programs, with exactly the permissions the device gives this app. Whether that works depends on how the app is installed (see Setup requirements)."
        case .localhostSSH:
            "You may sign in to an SSH service already running on this device (127.0.0.1) with that service's own account. The host key is verified like any other host."
        case .expandedFileRead:
            "Unleashed can list and read locations outside the app sandbox that the device lets this app read."
        case .expandedFileWrite:
            "Unleashed can create, edit, rename and delete items in those locations where the device allows writing. System and jailbreak locations still ask before every change."
        case .packageManagement:
            "Unleashed reads the installed-package list (from the dpkg status file when it is readable). Installing, removing or refreshing packages is offered only when a local shell works, and each one needs your approval and runs visibly."
        case .processInspection:
            "Diagnostics and Unleashed Tools list running processes, as far as the system shows them to this app."
        case .privilegedOperations:
            "Commands that ask for elevated rights or change device state (sudo, su, launchctl, writes to system paths, …) can be approved one at a time. HCG Terminal never supplies passwords or elevates by itself."
        case .remoteSSH:
            "You can connect to your hosts over SSH. Host keys are always verified."
        case .remoteBuilds:
            "You can run builds and tests on a connected host and download their artifacts."
        }
    }

    public var whenOff: String {
        switch self {
        case .workspaceCommands:
            "New Vanilla sessions cannot be opened, and open ones refuse new commands. Workspace files and command history are kept."
        case .externalFiles:
            "Import and export are refused. Files already imported stay in the workspace."
        case .unleashedFeatures:
            "No Unleashed feature is used: no local shell, no localhost SSH, no browsing outside the sandbox, no package inventory. Open local shells are stopped after you confirm. Vanilla and remote development are unaffected."
        case .localShell:
            "No shell or program is started on this device, and open local shells are stopped after you confirm. Privileged operations and package changes stop too, because they need it. The package inventory and file browsing keep working."
        case .localhostSSH:
            "HCG Terminal does not connect to SSH services on this device; open localhost sessions are disconnected after you confirm. Remote SSH to other hosts is controlled separately."
        case .expandedFileRead:
            "Locations outside the sandbox cannot be listed or read. Writing stops too, because it needs reading. Nothing on the device is changed or removed."
        case .expandedFileWrite:
            "Locations outside the sandbox are read-only for HCG Terminal. Earlier changes are not undone."
        case .packageManagement:
            "Package lists are not read and package changes are not offered. Installed packages are not touched."
        case .processInspection:
            "The process table is not read."
        case .privilegedOperations:
            "Privileged commands HCG Terminal recognizes are refused instead of offered for approval. A program you start can still ask for its own elevation (for example a script that runs sudo); HCG Terminal cannot prevent that."
        case .remoteSSH:
            "No SSH connection is opened and open SSH sessions are disconnected. Remote builds stop too, because they need SSH. Saved hosts, keys and passwords are kept."
        case .remoteBuilds:
            "Builds and tests cannot be started and a running one is cancelled. Logs, history and downloaded artifacts are kept."
        }
    }

    /// What turning it off does to sessions or builds that are running.
    public var activeSessionEffect: String {
        switch self {
        case .workspaceCommands: "Open Vanilla sessions are ended after you confirm."
        case .unleashedFeatures, .localShell: "Open local shells and programs are stopped after you confirm (the processes are ended and their exit is confirmed)."
        case .localhostSSH: "Open localhost SSH sessions are disconnected after you confirm. Programs started through them may keep running; that is not verified."
        case .remoteSSH: "Open SSH sessions are disconnected after you confirm. Programs you started on the host may keep running there; HCG Terminal cannot confirm that they stopped."
        case .remoteBuilds: "A running build is cancelled after you confirm: the channel is closed and the remote process group is sent TERM. Whether it stopped is shown in the log, not assumed."
        case .externalFiles, .expandedFileRead, .expandedFileWrite, .packageManagement, .processInspection, .privilegedOperations:
            "Takes effect for the next operation; nothing running is interrupted."
        }
    }
}

/// Why HCG Terminal refused an operation.
public struct AccessDenied: Error, LocalizedError, Hashable, Sendable {
    public var control: AccessControl
    /// Set when the control itself is on but a prerequisite is off.
    public var blockedBy: AccessControl?

    public init(control: AccessControl, blockedBy: AccessControl? = nil) {
        self.control = control
        self.blockedBy = blockedBy
    }

    public var errorDescription: String? {
        if let blockedBy {
            return "\(control.title) needs “\(blockedBy.title)”, which is turned off in Settings → Capabilities & Access."
        }
        return "“\(control.title)” is turned off in Settings → Capabilities & Access."
    }
}

/// Persisted user switches. Stored as a string → bool map so unknown keys from newer versions
/// survive and missing keys fall back to the defaults.
public struct AccessSettings: Codable, Hashable, Sendable {
    public var values: [String: Bool]

    public init(values: [String: Bool] = [:]) {
        self.values = values
    }

    public static let defaults = AccessSettings()

    public func isOn(_ control: AccessControl) -> Bool {
        values[control.rawValue] ?? control.defaultEnabled
    }

    public mutating func set(_ control: AccessControl, _ enabled: Bool) {
        values[control.rawValue] = enabled
    }
}

/// Where settings are kept.
public protocol AccessSettingsStorage: Sendable {
    func load() -> AccessSettings
    func save(_ settings: AccessSettings)
}

/// `UserDefaults` storage (the app).
public struct UserDefaultsAccessStorage: AccessSettingsStorage, @unchecked Sendable {
    public static let key = "hcg.terminal.access.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AccessSettings {
        guard let data = defaults.data(forKey: Self.key), let settings = try? JSONDecoder().decode(AccessSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    public func save(_ settings: AccessSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }
}

/// In-memory storage (tests, previews).
public final class MemoryAccessStorage: AccessSettingsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AccessSettings

    public init(_ settings: AccessSettings = .defaults) {
        self.stored = settings
    }

    public func load() -> AccessSettings { lock.withLock { stored } }
    public func save(_ settings: AccessSettings) { lock.withLock { stored = settings } }
}

/// The switches every service checks before it acts. Thread-safe; read synchronously on every
/// operation so a change applies to the very next one.
public final class AccessPolicy: @unchecked Sendable {
    /// The app's policy, persisted in `UserDefaults`. Services use it unless they are given
    /// another one, so turning a switch off is enforced even by code paths the UI does not show.
    public static let shared = AccessPolicy(storage: UserDefaultsAccessStorage())

    private let lock = NSLock()
    private let storage: any AccessSettingsStorage
    private var current: AccessSettings
    private var observers: [UUID: @Sendable (AccessSettings) -> Void] = [:]

    public init(storage: any AccessSettingsStorage) {
        self.storage = storage
        self.current = storage.load()
    }

    /// A policy with the default switches, kept in memory.
    public static func inMemory(_ settings: AccessSettings = .defaults) -> AccessPolicy {
        AccessPolicy(storage: MemoryAccessStorage(settings))
    }

    /// A policy with every switch on, kept in memory (tests of unrelated behavior).
    public static func allEnabled() -> AccessPolicy {
        var settings = AccessSettings()
        for control in AccessControl.allCases { settings.set(control, true) }
        return inMemory(settings)
    }

    public var settings: AccessSettings { lock.withLock { current } }

    /// The user's own choice for this switch, ignoring prerequisites.
    public func isOn(_ control: AccessControl) -> Bool { settings.isOn(control) }

    /// The first prerequisite (direct or indirect) that is off, if any.
    public func blockingPrerequisite(of control: AccessControl) -> AccessControl? {
        let snapshot = settings
        func firstOff(_ control: AccessControl, depth: Int) -> AccessControl? {
            guard depth < 8 else { return nil }
            for prerequisite in control.prerequisites {
                if !snapshot.isOn(prerequisite) { return prerequisite }
                if let deeper = firstOff(prerequisite, depth: depth + 1) { return deeper }
            }
            return nil
        }
        return firstOff(control, depth: 0)
    }

    /// On, and every prerequisite on.
    public func isEnabled(_ control: AccessControl) -> Bool {
        isOn(control) && blockingPrerequisite(of: control) == nil
    }

    /// Throws `AccessDenied` unless the switch and all its prerequisites are on.
    public func require(_ control: AccessControl) throws {
        guard isOn(control) else { throw AccessDenied(control: control) }
        if let blocker = blockingPrerequisite(of: control) { throw AccessDenied(control: control, blockedBy: blocker) }
    }

    /// The refusal message for `control`, or `nil` when it is enabled.
    public func denial(_ control: AccessControl) -> String? {
        do { try require(control); return nil } catch { return error.localizedDescription }
    }

    public func requireAll(_ controls: [AccessControl]) throws {
        for control in controls { try require(control) }
    }

    /// Switches that would stop working (themselves or through prerequisites) if `control`
    /// were set to `enabled`, compared with now.
    public func newlyDisabled(ifSetting control: AccessControl, to enabled: Bool) -> [AccessControl] {
        var proposed = settings
        proposed.set(control, enabled)
        let preview = AccessPolicy.inMemory(proposed)
        return AccessControl.allCases.filter { isEnabled($0) && !preview.isEnabled($0) }
    }

    public func set(_ control: AccessControl, enabled: Bool) {
        let updated: AccessSettings = lock.withLock {
            current.set(control, enabled)
            return current
        }
        storage.save(updated)
        notify(updated)
    }

    /// Restores the factory settings (expanded write and privileged operations off).
    public func resetToDefaults() {
        lock.withLock { current = .defaults }
        storage.save(.defaults)
        notify(.defaults)
    }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (AccessSettings) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return id
    }

    public func removeObserver(_ id: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: id) }
    }

    private func notify(_ settings: AccessSettings) {
        let handlers = lock.withLock { Array(observers.values) }
        for handler in handlers { handler(settings) }
    }
}
