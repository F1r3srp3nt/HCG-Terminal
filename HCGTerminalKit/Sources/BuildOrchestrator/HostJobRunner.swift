import DeveloperWorkspace
import Diagnostics
import Foundation
import TerminalCore

/// Drives detached host jobs: start (idempotent), follow, reattach after a disconnection,
/// cancel, and collect results. All job state is persisted after every step, so the app can be
/// closed or lose its connection at any point without losing the job or starting it twice.
///
/// A dropped connection never changes a job's outcome: only the exit status written by the job
/// on the host does.
public actor HostJobRunner {
    public let store: HostJobStore
    private var redactor: SecretRedactor
    private let access: AccessPolicy
    /// Jobs currently being followed by this runner (one follower per job).
    private var following: Set<UUID> = []

    public init(store: HostJobStore, redactor: SecretRedactor = SecretRedactor(), access: AccessPolicy = .shared) {
        self.store = store
        self.redactor = redactor
        self.access = access
    }

    public func setRedactor(_ redactor: SecretRedactor) { self.redactor = redactor }

    /// Records a new job locally. Nothing is sent yet.
    public func create(_ plan: BuildPlan, doctorReportID: UUID? = nil, now: Date = Date()) async -> HostJob {
        let id = UUID()
        let stamp = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let job = HostJob(
            id: id, plan: plan, createdAt: now, finishedAt: nil, state: .starting, receivedBytes: 0,
            logFileName: "job-\(stamp)-\(id.uuidString.prefix(8)).log", artifacts: [], executableMakerBuildID: nil,
            firstFailure: nil, doctorReportID: doctorReportID, disconnectedAt: nil, lastContact: nil
        )
        await store.save(job)
        return job
    }

    public func isFollowing(_ id: UUID) -> Bool { following.contains(id) }

    /// Starts the job if needed, then follows it until it ends or the connection drops.
    /// `onLines` receives redacted lines in order. Safe to call again after a disconnection: it
    /// reattaches at the saved offset and never starts a second build.
    @discardableResult
    public func drive(_ id: UUID, executor: any RemoteCommandExecuting, hostAllowsBuilds: Bool = true, onLines: @escaping @Sendable ([String]) async -> Void = { _ in }) async -> HostJob? {
        guard var job = await store.job(id) else { return nil }
        guard job.state.isActive else { return job }
        guard !following.contains(id) else { return job }
        following.insert(id)
        defer { following.remove(id) }
        let client = HostJobClient(executor: executor)

        if job.state == .starting {
            if let refusal = access.denial(.remoteBuilds) {
                return await finish(&job, .couldNotStart(refusal))
            }
            guard hostAllowsBuilds else {
                return await finish(&job, .couldNotStart("Builds are turned off for \(job.plan.hostName) in its host settings. Nothing was sent to the host."))
            }
            guard executor.endpoint.hostID == job.plan.hostID else {
                return await finish(&job, .couldNotStart("The job belongs to \(job.plan.hostName), not \(executor.endpoint.displayName)."))
            }
            do {
                let outcome = try await client.start(job)
                job.state = .running
                job.lastContact = Date()
                job.disconnectedAt = nil
                await store.save(job)
                await DiagnosticLog.shared.record(.info, "jobs", outcome == .started ? "Job started" : "Job start confirmed (already running)", metadata: ["job": job.shortID, "host": job.plan.hostName])
            } catch let error as HostJobError {
                return await finish(&job, .couldNotStart(error.localizedDescription))
            } catch {
                // The request may or may not have reached the host. The job stays "starting";
                // the next attempt sends the same ID, which the host will not start twice.
                job.disconnectedAt = Date()
                await store.save(job)
                return job
            }
        }

        // Follow from the saved offset.
        let state = FollowState(offset: job.receivedBytes, redactor: redactor)
        let store = self.store
        let jobID = job.id
        let end = await client.follow(jobID, from: job.receivedBytes) { data in
            let (clean, offset) = await state.consume(data)
            guard !clean.isEmpty, var current = await store.job(jobID) else { return }
            await store.appendLog(clean, to: current)
            current.receivedBytes = offset
            current.lastContact = Date()
            current.disconnectedAt = nil
            await store.save(current)
            await onLines(clean)
        }
        job = await store.job(jobID) ?? job

        switch end {
        case .disconnected:
            // Keep the job active: as far as anyone knows it is still running on the host.
            job.disconnectedAt = job.disconnectedAt ?? Date()
            await store.save(job)
            return job
        case .missing:
            return await finish(&job, .lost("its folder no longer exists on the host"))
        case .lost:
            await storeTail(state, &job, onLines: onLines)
            return await finish(&job, .lost("the process stopped without recording an exit status (for example the host restarted)"))
        case .cancelled:
            await storeTail(state, &job, onLines: onLines)
            return await finish(&job, .cancelled)
        case .exited(let code):
            await storeTail(state, &job, onLines: onLines)
            if code == 0, let artifacts = try? await client.artifacts(for: job) { job.artifacts = artifacts }
            return await finish(&job, code == 0 ? .succeeded : .failed(exitStatus: code))
        }
    }

    private func storeTail(_ state: FollowState, _ job: inout HostJob, onLines: @Sendable ([String]) async -> Void) async {
        let (clean, offset) = await state.flush()
        guard !clean.isEmpty else { return }
        await store.appendLog(clean, to: job)
        job.receivedBytes = offset
        await onLines(clean)
    }

    private func finish(_ job: inout HostJob, _ state: HostJobState) async -> HostJob {
        job.state = state
        job.finishedAt = Date()
        job.disconnectedAt = nil
        let lines = await store.log(for: job).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if case .executableMaker = job.plan.system {
            let report = ExecutableMakerCLI.parse(lines)
            job.executableMakerBuildID = report.buildID
            for index in job.artifacts.indices {
                if let reported = report.artifacts.first(where: { $0.path == job.artifacts[index].sourcePath }) {
                    job.artifacts[index].verification = reported.verification
                    job.artifacts[index].checks = reported.checks
                }
            }
        }
        if state != .succeeded, state != .cancelled, let failure = FailureLocator.firstFailure(in: lines) {
            job.firstFailure = StoredFailure(failure)
        }
        await store.save(job)
        await DiagnosticLog.shared.record(state == .succeeded ? .info : .warning, "jobs", "Job finished", metadata: ["job": job.shortID, "host": job.plan.hostName, "state": state.label])
        return job
    }

    /// Asks the host to stop the job. The job's state changes only when the host confirms it
    /// (the follower sees the exit), or here when it had already ended.
    public func cancel(_ id: UUID, executor: any RemoteCommandExecuting) async throws -> String {
        guard var job = await store.job(id) else { return "NOTFOUND" }
        let reply = try await HostJobClient(executor: executor).cancel(id)
        if reply == "NOTFOUND", job.state == .starting {
            // The start never reached the host; there is nothing to stop.
            _ = await finish(&job, .cancelled)
        }
        return reply
    }

    /// Asks the host where the job stands (for jobs not being followed, e.g. after a restart).
    public func reconcile(_ id: UUID, executor: any RemoteCommandExecuting) async throws -> HostJob? {
        guard var job = await store.job(id), job.state.isActive, !following.contains(id) else { return await store.job(id) }
        let status = try await HostJobClient(executor: executor).status(id)
        switch status {
        case .missing where job.state == .starting:
            return job // never reached the host; `drive` will start it with the same ID
        case .missing:
            return await finish(&job, .lost("its folder no longer exists on the host"))
        case .starting, .running:
            job.state = .running
            job.lastContact = Date()
            await store.save(job)
            return job
        case .exited, .cancelled, .lost:
            // Let the follower read the rest of the log and record the outcome.
            job.state = .running
            await store.save(job)
            return job
        }
    }

    /// Removes the job's folder on the host (log and packed products), then forgets it here.
    public func removeEverywhere(_ id: UUID, executor: any RemoteCommandExecuting) async throws -> Bool {
        guard let job = await store.job(id), !job.state.isActive else { return false }
        let removed = try await HostJobClient(executor: executor).remove(id)
        if removed { await store.remove(id) }
        return removed
    }
}

/// Splits, redacts and counts streamed log bytes. The resume offset only advances past lines
/// that were stored.
actor FollowState {
    private var offset: Int64
    private var splitter = ByteLineSplitter()
    private var pem = SecretRedactor.PEMState()
    private let redactor: SecretRedactor

    init(offset: Int64, redactor: SecretRedactor) {
        self.offset = offset
        self.redactor = redactor
    }

    func consume(_ data: Data) -> ([String], Int64) {
        let (lines, bytes) = splitter.append(data)
        offset += bytes
        return (lines.map { pem.process($0, redactor: redactor) }, offset)
    }

    func flush() -> ([String], Int64) {
        let (lines, bytes) = splitter.flush()
        offset += bytes
        return (lines.map { pem.process($0, redactor: redactor) }, offset)
    }
}
