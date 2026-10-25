import Foundation
import Testing
@testable import Scriberman

@Suite
struct SessionJobsTests {
    private let jobs = SessionJobs()
    private let sessionID = UUID()

    @Test
    func aDeleteMovesTheGenerationOn() async {
        let before = jobs.generation(of: sessionID)
        #expect(jobs.isCurrent(before))
        #expect(jobs.mayWrite(before))

        await jobs.cancelAndDrain(sessionID)

        #expect(!jobs.isCurrent(before))
        #expect(!jobs.mayWrite(before))
        #expect(jobs.isCurrent(jobs.generation(of: sessionID)))
    }

    @Test
    func aDeleteLeavesOtherSessionsGenerationsAlone() async {
        let other = jobs.generation(of: UUID())

        await jobs.cancelAndDrain(sessionID)

        #expect(jobs.isCurrent(other))
    }

    @Test
    func aDeleteCancelsATrackedTaskAndReturnsOnceItHasStopped() async {
        let stopped = JobFlag()
        let task = Task {
            try? await Task.sleep(for: .seconds(60))
            await stopped.set()
        }
        jobs.track(task, as: jobs.generation(of: sessionID))

        await jobs.cancelAndDrain(sessionID)

        #expect(task.isCancelled)
        #expect(await stopped.isSet)
    }

    @Test
    func aDeleteWaitsOutATaskThatIgnoresCancellation() async throws {
        let gate = JobGate()
        let finished = JobFlag()
        let task = Task {
            await gate.wait()
            await finished.set()
        }
        jobs.track(task, as: jobs.generation(of: sessionID))
        await gate.untilWaiting()

        let drain = Task { [jobs, sessionID] in
            await jobs.cancelAndDrain(sessionID)
            return await finished.isSet
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !finished.isSet)

        await gate.open()
        #expect(await drain.value)
    }

    @Test
    func aTaskTrackedAfterADeleteOfItsGenerationIsCancelledAtOnce() async {
        let stale = jobs.generation(of: sessionID)
        await jobs.cancelAndDrain(sessionID)

        let task = Task { try? await Task.sleep(for: .seconds(60)) }
        jobs.track(task, as: stale)
        await task.value

        #expect(task.isCancelled)
    }

    @Test
    func aDeleteDoesNotCancelAnotherSessionsTask() async {
        let task = Task { try? await Task.sleep(for: .milliseconds(200)) }
        jobs.track(task, as: jobs.generation(of: UUID()))

        await jobs.cancelAndDrain(sessionID)

        #expect(!task.isCancelled)
        task.cancel()
    }

    @Test
    func aJobRunThroughRunIsCancelledByADeleteAndMayNotWrite() async {
        let gate = JobGate()
        let job = Task { [jobs, sessionID] in
            await jobs.run(sessionID) { generation in
                await gate.waitCancellably()
                return jobs.mayWrite(generation)
            }
        }
        await gate.untilWaiting()

        await jobs.cancelAndDrain(sessionID)

        #expect(await job.value == false)
    }

    @Test
    func aJobRunThroughRunIsCancelledWithTheTaskThatAwaitsIt() async {
        let gate = JobGate()
        let job = Task { [jobs, sessionID] in
            await jobs.run(sessionID) { _ in await gate.waitCancellably() }
        }
        await gate.untilWaiting()

        job.cancel()

        #expect(await job.value)
    }
}

/// Holds whoever waits on it until `open()`, and lets a test wait until someone is held.
actor JobGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var cancellableWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledBeforeWaiting: Set<UUID> = []
    private var waitingCount = 0
    private var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Waits until the gate opens, ignoring cancellation: a step that cannot be interrupted.
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            arrive()
        }
    }

    /// Waits until the gate opens or the task is cancelled. Returns whether it was cancelled.
    @discardableResult
    func waitCancellably() async -> Bool {
        guard !isOpen else { return false }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledBeforeWaiting.remove(id) != nil {
                    continuation.resume()
                } else {
                    cancellableWaiters[id] = continuation
                    arrive()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        return Task.isCancelled
    }

    /// Returns once `count` waits have reached the gate.
    func untilWaiting(_ count: Int = 1) async {
        guard waitingCount < count else { return }
        await withCheckedContinuation { arrivalWaiters.append((count, $0)) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        cancellableWaiters.values.forEach { $0.resume() }
        cancellableWaiters.removeAll()
    }

    private func arrive() {
        waitingCount += 1
        let ready = arrivalWaiters.filter { $0.count <= waitingCount }
        arrivalWaiters.removeAll { $0.count <= waitingCount }
        ready.forEach { $0.continuation.resume() }
    }

    private func cancelWaiter(_ id: UUID) {
        if let continuation = cancellableWaiters.removeValue(forKey: id) {
            continuation.resume()
        } else {
            cancelledBeforeWaiting.insert(id)
        }
    }
}

actor JobFlag {
    private(set) var isSet = false

    func set() {
        isSet = true
    }
}
