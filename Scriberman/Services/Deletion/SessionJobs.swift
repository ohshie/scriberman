import Foundation
import os

/// The background jobs working on each session, so that a delete can stop them before anything
/// moves.
///
/// Each session has a generation, which every delete moves on. A job captures it when it starts
/// and asks `mayWrite` before every store write and file change; a job that started before a
/// delete then writes nothing, even when it finishes after an undo has put back a record with the
/// same `id`. A job that runs in its own task also hands the task to `track`, or runs through
/// `run`, so that a delete cancels it and waits for it to stop.
final class SessionJobs: Sendable {
    struct Generation: Hashable, Sendable {
        let sessionID: UUID
        fileprivate let value: Int
        /// Captured while a delete of the session was under way, so never current.
        fileprivate let isDuringDelete: Bool
    }

    private struct Job: Sendable {
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    private struct State {
        var generations: [UUID: Int] = [:]
        var jobs: [UUID: [UUID: Job]] = [:]
        var draining: Set<UUID> = []
        var folders: [UUID: URL] = [:]
        var deleting: Set<UUID> = []

        func isCurrent(_ generation: Generation) -> Bool {
            !generation.isDuringDelete
                && !deleting.contains(generation.sessionID)
                && generations[generation.sessionID, default: 0] == generation.value
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    func generation(of sessionID: UUID) -> Generation {
        state.withLock { state in
            Generation(
                sessionID: sessionID,
                value: state.generations[sessionID, default: 0],
                isDuringDelete: state.deleting.contains(sessionID)
            )
        }
    }

    func isCurrent(_ generation: Generation) -> Bool {
        state.withLock { $0.isCurrent(generation) }
    }

    /// Whether a job of `generation` may still write: its session has not been deleted since the
    /// job started, no delete of it is under way, and the task it runs in has not been cancelled.
    func mayWrite(_ generation: Generation) -> Bool {
        !Task.isCancelled && isCurrent(generation)
    }

    /// Has a delete of the session cancel `task` and wait for it. A task tracked while its session
    /// is being deleted, or with a generation a delete has already moved on from, is cancelled at
    /// once.
    func track<Success: Sendable, Failure: Error>(_ task: Task<Success, Failure>, as generation: Generation) {
        let sessionID = generation.sessionID
        let jobID = UUID()
        let job = Job(cancel: { task.cancel() }, wait: { _ = await task.result })
        let isStale = state.withLock { state in
            let isDraining = state.draining.contains(sessionID)
            let isCurrent = state.isCurrent(generation)
            // While draining, the delete waits for it too.
            if isDraining || isCurrent {
                state.jobs[sessionID, default: [:]][jobID] = job
            }
            return isDraining || !isCurrent
        }
        if isStale {
            task.cancel()
        }
        Task { [weak self] in
            await job.wait()
            self?.remove(jobID, of: sessionID)
        }
    }

    /// Runs `operation` in a task of its own, tracked as a job of `sessionID` and cancelled with
    /// the task that awaits it. `operation` gets the generation it started in.
    func run<Success: Sendable>(
        _ sessionID: UUID,
        _ operation: @escaping @Sendable (Generation) async -> Success
    ) async -> Success {
        let generation = generation(of: sessionID)
        let task = Task { await operation(generation) }
        track(task, as: generation)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Moves the session's generation on, cancels its jobs and returns once every one of them,
    /// including any tracked meanwhile, has stopped. A step that cannot be interrupted is waited
    /// out.
    func cancelAndDrain(_ sessionID: UUID) async {
        let running = state.withLock { state in
            state.generations[sessionID, default: 0] += 1
            state.draining.insert(sessionID)
            return Array(state.jobs[sessionID, default: [:]].values)
        }
        running.forEach { $0.cancel() }
        while true {
            let pending = state.withLock { $0.jobs[sessionID, default: [:]] }
            guard !pending.isEmpty else { break }
            for job in pending.values {
                await job.wait()
            }
            for jobID in pending.keys {
                remove(jobID, of: sessionID)
            }
        }
        state.withLock { _ = $0.draining.remove(sessionID) }
    }

    /// Starts a delete of the session: until `finishDeleting`, no generation of it is current, so
    /// a job that starts meanwhile, such as a sweep that fetched the record before it went, writes
    /// nothing. Then stops its jobs as `cancelAndDrain` does.
    func startDeleting(_ sessionID: UUID) async {
        state.withLock { _ = $0.deleting.insert(sessionID) }
        await cancelAndDrain(sessionID)
    }

    /// Ends the delete `startDeleting` began, whether it deleted the record or rolled back. A
    /// generation captured after this is current again.
    func finishDeleting(_ sessionID: UUID) {
        state.withLock { _ = $0.deleting.remove(sessionID) }
    }

    /// Records the folder a job created for a session whose record does not name it yet, such as
    /// an import's folder before conversion sets its mixdown, so a delete can remove it.
    func recordFolder(_ folder: URL, of sessionID: UUID) {
        state.withLock { $0.folders[sessionID] = folder }
    }

    /// The folder a job recorded for the session, forgotten as it is returned.
    func takeFolder(of sessionID: UUID) -> URL? {
        state.withLock { $0.folders.removeValue(forKey: sessionID) }
    }

    private func remove(_ jobID: UUID, of sessionID: UUID) {
        state.withLock { state in
            state.jobs[sessionID]?[jobID] = nil
            if state.jobs[sessionID]?.isEmpty == true {
                state.jobs[sessionID] = nil
            }
        }
    }
}
