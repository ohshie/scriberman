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
    }

    private struct Job: Sendable {
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }

    private struct State {
        var generations: [UUID: Int] = [:]
        var jobs: [UUID: [UUID: Job]] = [:]
        var draining: Set<UUID> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    func generation(of sessionID: UUID) -> Generation {
        state.withLock { Generation(sessionID: sessionID, value: $0.generations[sessionID, default: 0]) }
    }

    func isCurrent(_ generation: Generation) -> Bool {
        state.withLock { $0.generations[generation.sessionID, default: 0] == generation.value }
    }

    /// Whether a job of `generation` may still write: its session has not been deleted since the
    /// job started, and the task it runs in has not been cancelled.
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
            // While draining, the delete waits for it too.
            if isDraining || state.generations[sessionID, default: 0] == generation.value {
                state.jobs[sessionID, default: [:]][jobID] = job
            }
            return isDraining || state.generations[sessionID, default: 0] != generation.value
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

    private func remove(_ jobID: UUID, of sessionID: UUID) {
        state.withLock { state in
            state.jobs[sessionID]?[jobID] = nil
            if state.jobs[sessionID]?.isEmpty == true {
                state.jobs[sessionID] = nil
            }
        }
    }
}
