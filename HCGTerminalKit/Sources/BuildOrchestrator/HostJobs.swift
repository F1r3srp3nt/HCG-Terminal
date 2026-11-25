import DeveloperWorkspace
import Diagnostics
import Foundation
import TerminalCore

/// What a build produced, by how it can be used.
public enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case simulatorApp, deviceApp, ipa, xcarchive, macApp, deb, dotnetOutput, executable, other

    public var label: String {
        switch self {
        case .simulatorApp: "iOS Simulator app"
        case .deviceApp: "iOS app (device build)"
        case .ipa: "iOS app package (.ipa)"
        case .xcarchive: "Xcode archive"
        case .macApp: "macOS app"
        case .deb: "Debian package (.deb)"
        case .dotnetOutput: ".NET output"
        case .executable: "Executable"
        case .other: "File"
        }
    }
}

/// One product of a job, as listed by the host after the job finished.
public struct JobArtifact: Codable, Sendable, Hashable, Identifiable {
    public var kind: ArtifactKind
    public var name: String
    /// The file to download (directories are packed into a .zip or .tar in the job folder).
    public var remotePath: String
    /// Where the build put it.
    public var sourcePath: String
    public var size: Int64
    public var sha256: String
    public var bundleIdentifier: String?
    public var minimumOS: String?
    public var platform: String?
    /// HCG Executable Maker's own verification, when it built the artifact.
    public var verification: String?
    public var checks: [String]
    public var jobID: UUID
    public var id: String { remotePath }

    /// Packed from a directory (the download is the packed file, not the folder).
    public var wasPacked: Bool { remotePath != sourcePath }
}

public enum HostJobState: Codable, Sendable, Hashable {
    /// Recorded locally; the start request may or may not have reached the host yet.
    case starting
    case running
    case succeeded
    case failed(exitStatus: Int32)
    case cancelled
    /// The host has no exit status and the process is gone (for example the host restarted).
    case lost(String)
    case couldNotStart(String)

    public var isActive: Bool { self == .starting || self == .running }

    public var label: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .succeeded: "Succeeded (exit 0)"
        case .failed(let status): "Failed (exit \(status))"
        case .cancelled: "Cancelled"
        case .lost(let reason): "Ended without a result: \(reason)"
        case .couldNotStart(let reason): "Not started: \(reason)"
        }
    }
}

/// A build running (or run) as a detached job on a host.
public struct HostJob: Codable, Sendable, Hashable, Identifiable {
    /// Generated before the start request and sent with it: the idempotency key that keeps a
    /// retried start from launching a second build.
    public var id: UUID
    public var plan: BuildPlan
    public var createdAt: Date
    public var finishedAt: Date?
    public var state: HostJobState
    /// Raw log bytes consumed from the host so far (resume point after a disconnection).
    public var receivedBytes: Int64
    /// Local, redacted copy of the log.
    public var logFileName: String
    public var artifacts: [JobArtifact]
    public var executableMakerBuildID: String?
    public var firstFailure: StoredFailure?
    /// The Doctor report the plan was checked against.
    public var doctorReportID: UUID?
    /// When the phone last lost contact while the job was active (cleared on reattach).
    public var disconnectedAt: Date?
    public var lastContact: Date?

    public var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
    public var remoteDirectory: String { "$HOME/\(HostJobScripts.jobsRoot)/\(id.uuidString.lowercased())" }
}

/// `FailureContext`, stored with a job.
public struct StoredFailure: Codable, Sendable, Hashable {
    public var line: String
    public var kind: String
    public var before: [String]
    public var after: [String]
    public var isSummaryOnly: Bool

    public init(_ context: FailureContext) {
        line = context.line
        kind = context.kind.rawValue
        before = context.before
        after = context.after
        isSummaryOnly = context.isSummaryOnly
    }
}

/// The shell scripts that start, inspect, follow and cancel a detached job. POSIX `sh`; each is
/// sent as `/bin/sh -c '…'` so it does not depend on the user's interactive shell.
public enum HostJobScripts {
    public static let jobsRoot = ".hcg-terminal/jobs"
    public static let locksRoot = ".hcg-terminal/locks"
    public static let endMarker = "__HCG_JOB_END__"

    static func sh(_ script: String) -> String { "/bin/sh -c " + ShellQuote.quote(script) }

    static func dir(_ id: UUID) -> String { "\"$HOME\"/\(jobsRoot)/\(id.uuidString.lowercased())" }

    /// Stable key for "this project on this host", so two builds of it never run at once.
    public static func lockKey(projectPath: String, system: BuildSystem) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(projectPath)|\(system.label)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    /// The script the job runs, detached. `$1` is the job folder.
    static func runScript(job: HostJob) -> String {
        let plan = job.plan
        let inner = """
        printf '[hcg] job %s · %s\\n' \(ShellQuote.quote(job.shortID)) \(ShellQuote.quote(plan.title))
        printf '[hcg] host %s · user %s · %s\\n' "$(hostname 2>/dev/null)" "$(id -un 2>/dev/null)" "$(uname -sm)"
        printf '[hcg] PATH=%s\\n' "$PATH"
        command -v xcode-select >/dev/null 2>&1 && printf '[hcg] xcode-select -p: %s\\n' "$(xcode-select -p 2>&1)"
        printf '[hcg] $ %s\\n' \(ShellQuote.quote(plan.commandLine))
        \(RemoteShell.inDirectory(plan.projectPath, BuildPlanner.jobCommand(for: plan)))
        """
        let manifest = manifestScript(for: plan)
        return """
        J="$1"
        cd "$J" || exit 1
        echo $$ > pid.tmp && mv pid.tmp pid
        date -u +%Y-%m-%dT%H:%M:%SZ > started
        trap 'echo TERM >> signals' TERM
        trap 'echo INT >> signals' INT
        trap '' HUP
        HCG_JOB_DIR="$J" "${SHELL:-/bin/sh}" -lc \(ShellQuote.quote(inner)) >> out.log 2>&1 < /dev/null
        code=$?
        if [ "$code" = 0 ] && [ ! -f cancel ]; then
        ( \(manifest) ) > artifacts.tmp 2>> out.log && mv artifacts.tmp artifacts.tsv
        fi
        printf '[hcg] exit %s\\n' "$code" >> out.log
        printf '%s\\n' "$code" > exit.tmp && mv exit.tmp exit
        L=$(cat lockpath 2>/dev/null)
        if [ -n "$L" ] && [ "$(cat "$L/job" 2>/dev/null)" = \(ShellQuote.quote(job.id.uuidString.lowercased())) ]; then rm -rf "$L"; fi
        """
    }

    /// Lists and packs products after a successful build. Lines:
    /// `A<TAB>kind<TAB>name<TAB>size<TAB>sha256<TAB>downloadPath<TAB>sourcePath<TAB>bundleID<TAB>minOS<TAB>platform`.
    static func manifestScript(for plan: BuildPlan) -> String {
        let roots: String
        let filter: String
        switch plan.system {
        case .executableMaker:
            roots = "\"$J/output\""
            filter = "-maxdepth 2 \\( -name '*.app' -o -name '*.xcarchive' -o -name '*.ipa' \\) -prune"
        case .theos:
            roots = RemoteShell.quotePath(plan.projectPath) + "/packages"
            filter = "-maxdepth 1 -name '*.deb' -type f -newer \"$J/started\""
        case .xcodeProject, .xcodeWorkspace:
            roots = RemoteShell.quotePath(plan.projectPath) + "/" + BuildPlanner.derivedDataPath + "/Build/Products"
            filter = "-maxdepth 2 \\( -name '*.app' -o -name '*.ipa' -o -name '*.xcarchive' \\) -prune"
        case .swiftPackage:
            roots = RemoteShell.quotePath(plan.projectPath) + "/.build/" + plan.configuration.rawValue.lowercased()
            filter = "-maxdepth 1 -type f -perm -u+x ! -name '*.so' ! -name '*.dylib' ! -name '*.json'"
        case .dotnet:
            roots = RemoteShell.quotePath(plan.projectPath)
            filter = "-maxdepth 6 -path '*/bin/\(plan.configuration.rawValue)/*' \\( -name '*.dll' -o -name '*.exe' -o -name '*.nupkg' \\) -type f -newer \"$J/started\""
        }
        return """
        mkdir -p "$J/artifacts"
        sum() { (shasum -a 256 "$1" 2>/dev/null || sha256sum "$1") | cut -d' ' -f1; }
        plist() { [ -f "$1/Info.plist" ] && command -v plutil >/dev/null 2>&1 && plutil -extract "$2" raw -o - "$1/Info.plist" 2>/dev/null; }
        find -H \(roots) -mindepth 1 \(filter) -print 2>/dev/null | head -50 | while IFS= read -r p; do
          n=$(basename "$p"); bid=""; mos=""; plat=""
          case "$n" in
            *.ipa) k=ipa ;;
            *.xcarchive) k=xcarchive ;;
            *.deb) k=deb ;;
            *.dll|*.exe|*.nupkg) k=dotnetOutput ;;
            *.app)
              plat=$(plist "$p" DTPlatformName); bid=$(plist "$p" CFBundleIdentifier); mos=$(plist "$p" MinimumOSVersion)
              [ -z "$plat" ] && [ -f "$p/Contents/Info.plist" ] && { plat=macosx; bid=$(plutil -extract CFBundleIdentifier raw -o - "$p/Contents/Info.plist" 2>/dev/null); mos=$(plutil -extract LSMinimumSystemVersion raw -o - "$p/Contents/Info.plist" 2>/dev/null); }
              case "$plat$p" in iphonesimulator*|*-iphonesimulator/*) k=simulatorApp ;; iphoneos*|*-iphoneos/*) k=deviceApp ;; macosx*) k=macApp ;; *) k=other ;; esac ;;
            *) k=executable ;;
          esac
          if [ -d "$p" ]; then
            if command -v ditto >/dev/null 2>&1; then d="$J/artifacts/$n.zip"; ditto -c -k --keepParent "$p" "$d" || continue
            else d="$J/artifacts/$n.tar"; tar -C "$(dirname "$p")" -cf "$d" "$n" || continue; fi
          else
            d="$J/artifacts/$n"; cp -p "$p" "$d" || continue
          fi
          printf 'A\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$k" "$n" "$(wc -c < "$d" | tr -d ' ')" "$(sum "$d")" "$d" "$p" "$bid" "$mos" "$plat"
        done
        """
    }

    /// Starts the job unless it already exists. Prints one of:
    /// `STARTED <pid>`, `EXISTS`, `BUSY <job id>` (another live job holds this project's lock),
    /// `ERROR <message>`.
    public static func start(_ job: HostJob) -> String {
        let id = job.id.uuidString.lowercased()
        let lock = "\"$HOME\"/\(locksRoot)/" + lockKey(projectPath: job.plan.projectPath, system: job.plan.system)
        let meta = "id=\(id)\nhost=\(job.plan.hostName)\nproject=\(job.plan.projectPath)\ntitle=\(job.plan.title)\ncommand=\(job.plan.commandLine)\n"
        let script = """
        R="$HOME/.hcg-terminal"; J=\(dir(job.id)); L=\(lock)
        mkdir -p "$R/jobs" "$R/locks" 2>/dev/null || { echo "ERROR cannot create $R"; exit 0; }
        if [ -d "$J" ]; then echo EXISTS; exit 0; fi
        if ! mkdir "$L" 2>/dev/null; then
          o=$(cat "$L/job" 2>/dev/null)
          if [ -n "$o" ] && [ -f "$R/jobs/$o/pid" ] && [ ! -f "$R/jobs/$o/exit" ] && kill -0 "$(cat "$R/jobs/$o/pid")" 2>/dev/null; then echo "BUSY $o"; exit 0; fi
          if [ -n "$o" ] && [ -d "$R/jobs/$o" ] && [ ! -f "$R/jobs/$o/pid" ]; then echo "BUSY $o"; exit 0; fi
          rm -rf "$L"; mkdir "$L" 2>/dev/null || { echo "BUSY unknown"; exit 0; }
        fi
        printf '%s\\n' \(id) > "$L/job"
        if ! mkdir "$J" 2>/dev/null; then echo EXISTS; exit 0; fi
        printf '%s' \(ShellQuote.quote(runScript(job: job))) > "$J/run.sh"
        printf '%s' \(ShellQuote.quote(meta)) > "$J/meta"
        printf '%s\\n' "$L" > "$J/lockpath"
        : > "$J/out.log"
        cd "$J" || { echo "ERROR cannot enter $J"; exit 0; }
        if command -v perl >/dev/null 2>&1; then
          nohup perl -e 'use POSIX (); POSIX::setsid(); POSIX::close($_) for 3 .. 1023; exec @ARGV or exit 127' /bin/sh "$J/run.sh" "$J" > /dev/null 2>&1 < /dev/null 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
        else
          nohup /bin/sh "$J/run.sh" "$J" > /dev/null 2>&1 < /dev/null 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
        fi
        i=0; while [ ! -f "$J/pid" ] && [ $i -lt 50 ]; do sleep 0.1 2>/dev/null || sleep 1; i=$((i+1)); done
        echo "STARTED $(cat "$J/pid" 2>/dev/null)"
        """
        return sh(script)
    }

    /// `MISSING`, `STARTING`, `RUNNING <pid> <bytes>`, `EXITED <code> <bytes>`,
    /// `CANCELLED <code> <bytes>` or `LOST <bytes>`.
    public static func status(_ id: UUID) -> String {
        sh("""
        J=\(dir(id))
        [ -d "$J" ] || { echo MISSING; exit 0; }
        s=$(wc -c < "$J/out.log" 2>/dev/null | tr -d ' '); s=${s:-0}
        if [ -f "$J/exit" ]; then if [ -f "$J/cancel" ]; then echo "CANCELLED $(cat "$J/exit") $s"; else echo "EXITED $(cat "$J/exit") $s"; fi; exit 0; fi
        if [ ! -f "$J/pid" ]; then echo STARTING; exit 0; fi
        if kill -0 "$(cat "$J/pid")" 2>/dev/null; then echo "RUNNING $(cat "$J/pid") $s"; exit 0; fi
        sleep 1; if [ -f "$J/exit" ]; then echo "EXITED $(cat "$J/exit") $s"; else echo "LOST $s"; fi
        """)
    }

    /// Streams the log from byte `offset` (stdout) until the job ends, then writes the end
    /// marker and final status to stderr. Polls once a second; a dropped connection simply ends
    /// the stream, and the job continues.
    public static func follow(_ id: UUID, from offset: Int64) -> String {
        sh("""
        J=\(dir(id)); o=\(max(0, offset))
        [ -d "$J" ] || { echo "\(endMarker) MISSING" >&2; exit 0; }
        drain() { s=$(wc -c < "$J/out.log" 2>/dev/null | tr -d ' '); s=${s:-0}; if [ "$s" -gt "$o" ]; then tail -c +$((o+1)) "$J/out.log" | head -c $((s-o)); o=$s; fi; }
        while :; do
          drain
          if [ -f "$J/exit" ]; then drain; if [ -f "$J/cancel" ]; then echo "\(endMarker) CANCELLED $(cat "$J/exit")" >&2; else echo "\(endMarker) EXITED $(cat "$J/exit")" >&2; fi; exit 0; fi
          if [ -f "$J/pid" ] && ! kill -0 "$(cat "$J/pid")" 2>/dev/null; then sleep 1; [ -f "$J/exit" ] || { drain; echo "\(endMarker) LOST" >&2; exit 0; }; fi
          sleep 1
        done
        """)
    }

    /// Asks the job to stop: TERM to its process group, KILL after a grace period. Prints
    /// `ALREADY <code>`, `CANCELLED` or `NOTFOUND`.
    public static func cancel(_ id: UUID, graceSeconds: Int = 15) -> String {
        sh("""
        J=\(dir(id))
        [ -d "$J" ] || { echo NOTFOUND; exit 0; }
        [ -f "$J/exit" ] && { echo "ALREADY $(cat "$J/exit")"; exit 0; }
        : > "$J/cancel"
        p=$(cat "$J/pid" 2>/dev/null)
        if [ -n "$p" ]; then
          g=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')
          if [ "$g" = "$p" ]; then kill -TERM "-$p" 2>/dev/null; else pkill -TERM -P "$p" 2>/dev/null; fi
          i=0; while [ ! -f "$J/exit" ] && [ $i -lt \(graceSeconds) ]; do sleep 1; i=$((i+1)); done
          if [ ! -f "$J/exit" ]; then
            if [ "$g" = "$p" ]; then kill -KILL "-$p" 2>/dev/null; else pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; fi
            sleep 1
          fi
        fi
        if [ ! -f "$J/exit" ]; then printf '[hcg] cancelled; stopped with KILL\\n' >> "$J/out.log"; echo 137 > "$J/exit"; L=$(cat "$J/lockpath" 2>/dev/null); [ -n "$L" ] && [ "$(cat "$L/job" 2>/dev/null)" = \(ShellQuote.quote(id.uuidString.lowercased())) ] && rm -rf "$L"; fi
        echo CANCELLED
        """)
    }

    public static func artifacts(_ id: UUID) -> String {
        sh("J=\(dir(id)); cat \"$J/artifacts.tsv\" 2>/dev/null; true")
    }

    /// Deletes the job's folder (log and packed artifacts) on the host. Refused while it runs.
    public static func remove(_ id: UUID) -> String {
        sh("""
        J=\(dir(id))
        [ -d "$J" ] || { echo REMOVED; exit 0; }
        if [ ! -f "$J/exit" ] && [ -f "$J/pid" ] && kill -0 "$(cat "$J/pid")" 2>/dev/null; then echo RUNNING; exit 0; fi
        rm -rf "$J" && echo REMOVED
        """)
    }

    public static func parseArtifacts(_ text: String, jobID: UUID) -> [JobArtifact] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 10, f[0] == "A" else { return nil }
            func opt(_ s: String) -> String? { s.isEmpty ? nil : s }
            return JobArtifact(
                kind: ArtifactKind(rawValue: f[1]) ?? .other, name: f[2], remotePath: f[5], sourcePath: f[6],
                size: Int64(f[3]) ?? 0, sha256: f[4], bundleIdentifier: opt(f[7]), minimumOS: opt(f[8]), platform: opt(f[9]),
                verification: nil, checks: [], jobID: jobID
            )
        }
    }
}

/// The host's answer to a status query.
public enum HostJobStatus: Sendable, Equatable {
    case missing
    case starting
    case running(pid: Int32, logBytes: Int64)
    case exited(Int32, logBytes: Int64)
    case cancelled(Int32, logBytes: Int64)
    case lost(logBytes: Int64)

    public static func parse(_ text: String) -> HostJobStatus? {
        let f = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        func n(_ i: Int) -> Int64 { i < f.count ? Int64(f[i]) ?? 0 : 0 }
        switch f.first {
        case "MISSING": return .missing
        case "STARTING": return .starting
        case "RUNNING": return .running(pid: Int32(n(1)), logBytes: n(2))
        case "EXITED": return .exited(Int32(n(1)), logBytes: n(2))
        case "CANCELLED": return .cancelled(Int32(n(1)), logBytes: n(2))
        case "LOST": return .lost(logBytes: n(1))
        default: return nil
        }
    }
}

/// How a follow ended.
public enum FollowEnd: Sendable, Equatable {
    case exited(Int32)
    case cancelled(Int32)
    case lost
    case missing
    /// The connection dropped; the job may still be running.
    case disconnected(String)
}

public enum HostJobError: Error, LocalizedError, Equatable {
    case busy(otherJob: String)
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .busy(let other): "A build of this project is already running on the host (job \(other.prefix(8))). Open it instead of starting another."
        case .startFailed(let message): message
        }
    }
}

/// Starts, follows, reattaches and cancels detached jobs over any `RemoteCommandExecuting`.
/// Stateless: the caller persists `HostJob` after each step.
public struct HostJobClient: Sendable {
    public let executor: any RemoteCommandExecuting

    public init(executor: any RemoteCommandExecuting) {
        self.executor = executor
    }

    public enum StartOutcome: Sendable, Equatable {
        case started
        /// The job folder already existed: a previous start reached the host. Nothing new ran.
        case alreadyStarted
    }

    /// Idempotent: calling it again for the same job never starts a second build.
    public func start(_ job: HostJob) async throws -> StartOutcome {
        let result = try await executor.run(HostJobScripts.start(job))
        let line = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("STARTED") { return .started }
        if line == "EXISTS" { return .alreadyStarted }
        if line.hasPrefix("BUSY") { throw HostJobError.busy(otherJob: String(line.dropFirst(5))) }
        throw HostJobError.startFailed(line.hasPrefix("ERROR ") ? String(line.dropFirst(6)) : "The host did not confirm the start (\(line.isEmpty ? result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines) : line)).")
    }

    public func status(_ id: UUID) async throws -> HostJobStatus {
        let result = try await executor.run(HostJobScripts.status(id))
        guard let status = HostJobStatus.parse(result.stdoutText) else {
            throw HostJobError.startFailed("Unexpected status reply: \(result.stdoutText.prefix(120))")
        }
        return status
    }

    /// Streams log bytes after `offset`. `onData` receives raw chunks in order. Returns how the job
    /// ended, or `.disconnected` if the connection dropped first (never treated as a failure).
    public func follow(_ id: UUID, from offset: Int64, onData: @Sendable (Data) async -> Void) async -> FollowEnd {
        var stderrText = ""
        do {
            for try await event in executor.stream(HostJobScripts.follow(id, from: offset)) {
                switch event {
                case .stdout(let data): await onData(data)
                case .stderr(let data): stderrText += String(decoding: data, as: UTF8.self)
                case .exit: break
                }
            }
        } catch {
            return .disconnected(error.localizedDescription)
        }
        guard let line = stderrText.split(separator: "\n").last(where: { $0.hasPrefix(HostJobScripts.endMarker) }) else {
            return .disconnected(Task.isCancelled ? "Stopped following." : "The log stream ended early.")
        }
        let f = line.split(separator: " ").map(String.init)
        let code = f.count > 2 ? Int32(f[2]) ?? -1 : -1
        switch f.count > 1 ? f[1] : "" {
        case "EXITED": return .exited(code)
        case "CANCELLED": return .cancelled(code)
        case "LOST": return .lost
        case "MISSING": return .missing
        default: return .disconnected("Unexpected end: \(line)")
        }
    }

    public func cancel(_ id: UUID) async throws -> String {
        try await executor.run(HostJobScripts.cancel(id)).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func artifacts(for job: HostJob) async throws -> [JobArtifact] {
        HostJobScripts.parseArtifacts(try await executor.run(HostJobScripts.artifacts(job.id)).stdoutText, jobID: job.id)
    }

    public func remove(_ id: UUID) async throws -> Bool {
        try await executor.run(HostJobScripts.remove(id)).stdoutText.contains("REMOVED")
    }
}

/// Splits raw log bytes into lines, counting exactly how many bytes each consumed, so the resume
/// offset only ever advances past complete lines that were stored.
public struct ByteLineSplitter: Sendable {
    private var pending = Data()
    public init() {}

    /// Returns complete lines and the number of bytes they used (including newlines).
    public mutating func append(_ data: Data) -> (lines: [String], bytes: Int64) {
        pending.append(data)
        var lines: [String] = []
        var consumed = 0
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            var line = String(decoding: pending[start..<newline], as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if let cr = line.lastIndex(of: "\r") { line = String(line[line.index(after: cr)...]) }
            lines.append(line)
            consumed += newline - start + 1
            start = pending.index(after: newline)
        }
        pending = Data(pending[start...])
        // One enormous line without a newline is emitted rather than buffered forever.
        if pending.count > 256 * 1024 {
            lines.append(String(decoding: pending, as: UTF8.self))
            consumed += pending.count
            pending = Data()
        }
        return (lines, Int64(consumed))
    }

    /// The unterminated tail at the very end of a job.
    public mutating func flush() -> (lines: [String], bytes: Int64) {
        defer { pending = Data() }
        guard !pending.isEmpty else { return ([], 0) }
        return ([String(decoding: pending, as: UTF8.self)], Int64(pending.count))
    }
}

/// Persists jobs locally (JSON) and keeps their redacted logs.
public actor HostJobStore {
    private let directory: URL
    private let indexURL: URL
    private var jobs: [UUID: HostJob]

    public init(directory: URL) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("jobs.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: indexURL), let list = try? decoder.decode([HostJob].self, from: data) {
            jobs = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        } else {
            jobs = [:]
        }
    }

    public func all() -> [HostJob] { jobs.values.sorted { $0.createdAt > $1.createdAt } }
    public func job(_ id: UUID) -> HostJob? { jobs[id] }
    public func active() -> [HostJob] { all().filter(\.state.isActive) }

    public func save(_ job: HostJob) {
        jobs[job.id] = job
        if jobs.count > 300, let oldest = jobs.values.filter({ !$0.state.isActive }).min(by: { $0.createdAt < $1.createdAt }) {
            jobs[oldest.id] = nil
            try? FileManager.default.removeItem(at: logURL(for: oldest))
        }
        persist()
    }

    public func remove(_ id: UUID) {
        if let job = jobs.removeValue(forKey: id) { try? FileManager.default.removeItem(at: logURL(for: job)) }
        persist()
    }

    public func logURL(for job: HostJob) -> URL { directory.appendingPathComponent(job.logFileName) }

    /// Appends already-redacted lines to the job's local log.
    public func appendLog(_ lines: [String], to job: HostJob) {
        guard !lines.isEmpty else { return }
        let url = logURL(for: job)
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    public func log(for job: HostJob) -> String {
        (try? String(contentsOf: logURL(for: job), encoding: .utf8)) ?? ""
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(jobs.values)) { try? data.write(to: indexURL, options: .atomic) }
    }
}
