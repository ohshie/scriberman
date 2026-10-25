import AVFoundation
import Foundation
import SwiftData
import Testing
import os
@testable import Scriberman

/// Deleting a recording while the launch recovery sweep is working on it.
@MainActor
@Suite(.serialized)
final class RecordingRecoveryDeletionTests {
    private let workspace: Workspace
    private let workspaceService = MockWorkspaceService()
    private let container: ModelContainer
    private let context: ModelContext
    private let undoManager = UndoManager.forTests()
    private let jobs = SessionJobs()
    private lazy var coordinator = SessionDeletionCoordinator(
        workspaceService: workspaceService,
        announce: { _ in },
        startAccess: { _ in false },
        stopAccess: { _ in },
        sessionJobs: jobs
    )

    init() throws {
        workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: workspace.recordingsURL, withIntermediateDirectories: true)
        workspaceService.currentWorkspaceResult = workspace
        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    deinit {
        try? FileManager.default.removeItem(at: workspace.rootURL)
    }

    // MARK: - Fixtures

    private func folder(of session: RecordingSession) -> URL {
        URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
    }

    private func heldFolder(of session: RecordingSession) -> URL {
        HoldingFolder(workspace: workspace).heldFolder(for: session.id)
    }

    /// A recording whose folder has the raw inputs, so recovery mixes it down.
    private func makeRecordingAwaitingMixdown(_ name: String, status: RecordingStatus = .recorded) throws -> RecordingSession {
        let folder = workspace.recordingsURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let micURL = folder.appendingPathComponent("mic.wav")
        try Data("raw mic".utf8).write(to: micURL)
        let session = RecordingSession(
            createdAt: Date(timeIntervalSinceNow: -600),
            duration: 60,
            micAudioURL: micURL.path,
            title: name,
            status: status
        )
        context.insert(session)
        try context.save()
        return session
    }

    /// A recording whose finalization saved its mixdown and stopped before the screen mux and
    /// before retiring the raw inputs, so recovery retries the mux and retires the inputs.
    private func makeRecordingAwaitingMuxAndRetirement(_ name: String) throws -> RecordingSession {
        let folder = workspace.recordingsURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let micURL = folder.appendingPathComponent("mic.wav")
        let appURL = folder.appendingPathComponent("app.wav")
        for url in RecordingSourceFiles.sourceURLs(micURL: micURL, appURL: appURL) {
            try Data("raw \(url.lastPathComponent)".utf8).write(to: url)
        }
        let mixdownURL = folder.appendingPathComponent("recording.m4a")
        try writeValidMixdown(at: mixdownURL)
        try Data("screen tmp".utf8).write(to: RecordingFileLayout.screenTmpVideoURL(in: folder))
        let session = RecordingSession(
            duration: 60,
            micAudioURL: micURL.path,
            appAudioURL: appURL.path,
            mixdownURL: mixdownURL.path,
            title: name,
            status: .recorded
        )
        session.screenMuxState = ScreenMuxState.pending.rawValue
        session.videoStartHostTimeNanos = 2_000_000_000
        session.audioAnchorHostTimeNanos = 1_000_000_000
        context.insert(session)
        try context.save()
        return session
    }

    /// A short AAC file that `AVAudioFile` opens with a positive length.
    private func writeValidMixdown(at url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(
            forWriting: url,
            settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1]
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        try file.write(from: buffer)
    }

    /// A recovery service under the test's jobs. `atCheckpoint` runs the first time recovery asks
    /// whether `checkpointPath` exists.
    private func makeRecovery(
        checkpointPath: String = "",
        atCheckpoint: @escaping @Sendable () -> Void = {},
        performMixdown: @escaping RecordingRecoveryService.MixdownHandler = { _, _, _, _ in },
        performMux: @escaping RecordingRecoveryService.MuxHandler = { _ in }
    ) -> RecordingRecoveryService {
        RecordingRecoveryService(
            workspaceService: workspaceService,
            modelContainer: container,
            fileManager: CheckpointFileManager(path: checkpointPath, onFirstCheck: atCheckpoint),
            performMixdown: performMixdown,
            performMux: performMux,
            sessionJobs: jobs
        )
    }

    private func stored(_ id: UUID) throws -> RecordingSession? {
        try RecordingSession.fetch(id: id, in: ModelContext(container))
    }

    private func heldSnapshot(of session: RecordingSession) throws -> RecordingSessionRecord {
        let snapshot = try SessionSnapshot.read(from: heldFolder(of: session))
        guard case .recording(let record) = snapshot.session else {
            Issue.record("The held snapshot is not a recording.")
            throw CancellationError()
        }
        return record
    }

    private func contents(of folder: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return try Dictionary(uniqueKeysWithValues: names.map { name in
            (name, try Data(contentsOf: folder.appendingPathComponent(name)))
        })
    }

    private func startDeleting(_ session: RecordingSession) -> Task<JobsViewModel.DeletionResult, Never> {
        Task { await coordinator.delete(session, context: context, undoManager: undoManager) }
    }

    private func undo() async {
        undoManager.undo()
        await coordinator.waitUntilIdle()
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for a condition.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The start of a delete of `sessionID`, from inside a synchronous step of recovery: its jobs
    /// are being stopped and its record is still there. Returns once the delete has moved the
    /// session's generation on.
    private nonisolated static func startStoppingJobs(of sessionID: UUID, in jobs: SessionJobs) {
        let before = jobs.generation(of: sessionID)
        Task { await jobs.cancelAndDrain(sessionID) }
        let deadline = Date(timeIntervalSinceNow: 10)
        while jobs.isCurrent(before) {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for the delete to start.")
                return
            }
            usleep(1_000)
        }
    }

    // MARK: - Steps that run before any wait

    @Test
    func testACrashInterruptedRecordingWhoseDeleteHasStartedIsNotNormalized() async throws {
        let session = try makeRecordingAwaitingMixdown("Interrupted", status: .recording)
        let sessionID = session.id
        let jobs = jobs
        let checkpointPath = session.micAudioURL
        let mixdowns = OSAllocatedUnfairLock(initialState: 0)

        await makeRecovery(
            checkpointPath: checkpointPath,
            atCheckpoint: { Self.startStoppingJobs(of: sessionID, in: jobs) },
            performMixdown: { _, _, _, _ in mixdowns.withLock { $0 += 1 } }
        ).sweepIncompleteSessions()

        #expect(try stored(sessionID)?.status == .recording)
        #expect(mixdowns.withLock { $0 } == 0)
    }

    @Test
    func testACompletedMixdownIsNotAdoptedForARecordingWhoseDeleteHasStarted() async throws {
        let session = try makeRecordingAwaitingMuxAndRetirement("Adopt")
        session.mixdownURL = nil
        session.screenMuxState = nil
        try context.save()
        let sessionID = session.id
        let jobs = jobs
        let mixdownPath = folder(of: session).appendingPathComponent("recording.m4a").path
        let checkpointPath = mixdownPath
        let mixdowns = OSAllocatedUnfairLock(initialState: 0)

        await makeRecovery(
            checkpointPath: checkpointPath,
            atCheckpoint: { Self.startStoppingJobs(of: sessionID, in: jobs) },
            performMixdown: { _, _, _, _ in mixdowns.withLock { $0 += 1 } }
        ).sweepIncompleteSessions()

        #expect(try stored(sessionID)?.mixdownURL == nil)
        #expect(mixdowns.withLock { $0 } == 0)
        for url in RecordingSourceFiles.sourceURLs(
            micURL: URL(fileURLWithPath: session.micAudioURL),
            appURL: session.appAudioURL.map { URL(fileURLWithPath: $0) }
        ) {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    // MARK: - The session's own mixdown

    @Test
    func testDeleteDuringItsRecoveryMixdownWaitsItOutAndSavesNoMixdown() async throws {
        let session = try makeRecordingAwaitingMixdown("Mixing")
        let gate = JobGate()
        let recovery = makeRecovery(performMixdown: { _, _, outputURL, _ in
            await gate.wait()
            try Data("mixdown".utf8).write(to: outputURL)
        })
        let sweep = Task { await recovery.sweepIncompleteSessions() }
        await gate.untilWaiting()

        let deletion = startDeleting(session)
        try await eventually { self.coordinator.isRemoving(session.id) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.isRemoving(session.id))
        #expect(FileManager.default.fileExists(atPath: folder(of: session).path))
        await gate.open()

        #expect(await deletion.value == .deleted)
        await sweep.value
        #expect(try stored(session.id) == nil)
        #expect(try heldSnapshot(of: session).mixdownURL == nil)

        await undo()
        let restored = try #require(try stored(session.id))
        #expect(restored.mixdownURL == nil)
        #expect(restored.status == .recorded)
        #expect(restored.mixdownAttemptCount == 0)
    }

    @Test
    func testDeleteCancelsItsRecoveryMixdownAndCountsNoFailedAttempt() async throws {
        let session = try makeRecordingAwaitingMixdown("Cancelled")
        let gate = JobGate()
        let cancelled = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let recovery = makeRecovery(performMixdown: { _, _, _, _ in
            let wasCancelled = await gate.waitCancellably()
            cancelled.withLock { $0 = wasCancelled }
            throw CancellationError()
        })
        let sweep = Task { await recovery.sweepIncompleteSessions() }
        await gate.untilWaiting()

        let deletion = startDeleting(session)
        #expect(await deletion.value == .deleted)
        await gate.open()
        await sweep.value

        #expect(cancelled.withLock { $0 } == true)
        #expect((try heldSnapshot(of: session).mixdownAttemptCountValue ?? 0) == 0)
        await undo()
        let restored = try #require(try stored(session.id))
        #expect(restored.mixdownAttemptCount == 0)
        #expect(restored.status == .recorded)
    }

    // MARK: - Fetched while the delete is under way

    /// A coordinator under the test's jobs that runs `sweep` to the end, on the main actor's
    /// behalf, once the delete has stopped the session's jobs and before it moves the folder.
    private func makeCoordinator(
        sweepingWith recovery: RecordingRecoveryService,
        saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) -> SessionDeletionCoordinator {
        let hasSwept = OSAllocatedUnfairLock(initialState: false)
        return SessionDeletionCoordinator(
            workspaceService: workspaceService,
            saveContext: saveContext,
            announce: { _ in },
            startAccess: { _ in
                guard hasSwept.withLock({ swept in defer { swept = true }; return !swept }) else { return false }
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    await recovery.sweepIncompleteSessions()
                    done.signal()
                }
                done.wait()
                return false
            },
            stopAccess: { _ in },
            sessionJobs: jobs
        )
    }

    @Test
    func testRecoveryFetchingDuringADeleteWritesNothing() async throws {
        let session = try makeRecordingAwaitingMixdown("Fetched")
        let sessionID = session.id
        let mixdowns = OSAllocatedUnfairLock(initialState: 0)
        let recovery = makeRecovery(performMixdown: { _, _, outputURL, _ in
            mixdowns.withLock { $0 += 1 }
            try Data("mixdown".utf8).write(to: outputURL)
        })
        let coordinator = makeCoordinator(sweepingWith: recovery)

        #expect(await coordinator.delete(session, context: context, undoManager: undoManager) == .deleted)

        #expect(mixdowns.withLock { $0 } == 0)
        #expect(try stored(sessionID) == nil)
        #expect(try heldSnapshot(of: session).mixdownURL == nil)
        #expect(!FileManager.default.fileExists(atPath: heldFolder(of: session).appendingPathComponent("recording.m4a").path))
    }

    @Test
    func testARecordingWhoseDeleteRolledBackIsRecoverable() async throws {
        let session = try makeRecordingAwaitingMixdown("Rolled back")
        let sessionID = session.id
        let mixdowns = OSAllocatedUnfairLock(initialState: 0)
        let recovery = makeRecovery(performMixdown: { _, _, outputURL, _ in
            mixdowns.withLock { $0 += 1 }
            try Data("mixdown".utf8).write(to: outputURL)
        })
        let coordinator = makeCoordinator(
            sweepingWith: recovery,
            saveContext: { _ in throw CocoaError(.fileWriteUnknown) }
        )

        let result = await coordinator.delete(session, context: context, undoManager: undoManager)
        guard case .saveFailed = result else {
            Issue.record("Expected saveFailed, got \(result)")
            return
        }
        #expect(mixdowns.withLock { $0 } == 0)
        #expect(try stored(sessionID)?.mixdownURL == nil)

        await recovery.sweepIncompleteSessions()

        #expect(mixdowns.withLock { $0 } == 1)
        let recovered = try #require(try stored(sessionID))
        #expect(recovered.mixdownURL == folder(of: session).appendingPathComponent("recording.m4a").path)
        #expect(recovered.status == .recorded)
    }

    // MARK: - Deleted while recovery works on another session

    @Test
    func testARecordingDeletedDuringAnotherMixdownIsNotMixedDown() async throws {
        let first = try makeRecordingAwaitingMixdown("First")
        let second = try makeRecordingAwaitingMixdown("Second")
        let gate = JobGate()
        let outputs = OSAllocatedUnfairLock<[URL]>(initialState: [])
        let recovery = makeRecovery(performMixdown: { _, _, outputURL, _ in
            let count = outputs.withLock { outputs in
                outputs.append(outputURL)
                return outputs.count
            }
            if count == 1 {
                await gate.wait()
            }
        })
        let sweep = Task { await recovery.sweepIncompleteSessions() }
        await gate.untilWaiting()
        let mixing = try #require(outputs.withLock { $0 }.first)
        let other = folder(of: first) == mixing.deletingLastPathComponent() ? second : first
        let otherID = other.id

        #expect(await startDeleting(other).value == .deleted)
        await undo()
        await gate.open()
        await sweep.value

        #expect(outputs.withLock { $0 } == [mixing])
        let restored = try #require(try stored(otherID))
        #expect(restored.status == .recorded)
        #expect(restored.mixdownURL == nil)
        #expect(restored.mixdownAttemptCount == 0)
    }

    /// Deletes `session` and puts it back while recovery mixes down another recording.
    private func deleteAndRestoreDuringAnotherMixdown(
        _ session: RecordingSession,
        performMux: @escaping RecordingRecoveryService.MuxHandler = { _ in }
    ) async throws {
        _ = try makeRecordingAwaitingMixdown("Blocker")
        let gate = JobGate()
        let recovery = makeRecovery(performMixdown: { _, _, _, _ in await gate.wait() }, performMux: performMux)
        let sweep = Task { await recovery.sweepIncompleteSessions() }
        await gate.untilWaiting()

        #expect(await startDeleting(session).value == .deleted)
        await undo()
        await gate.open()
        await sweep.value
    }

    @Test
    func testARecordingDeletedDuringAnotherMixdownIsNotMuxed() async throws {
        let session = try makeRecordingAwaitingMuxAndRetirement("Mux")
        let sessionID = session.id
        let muxed = OSAllocatedUnfairLock<[UUID]>(initialState: [])

        try await deleteAndRestoreDuringAnotherMixdown(session, performMux: { request in
            muxed.withLock { $0.append(request.sessionID) }
        })

        #expect(!muxed.withLock { $0 }.contains(sessionID))
        let restored = try #require(try stored(sessionID))
        #expect(restored.screenMuxAttemptCount == 0)
        #expect(restored.screenMuxState == ScreenMuxState.pending.rawValue)
    }

    @Test
    func testARecordingDeletedDuringAnotherMixdownKeepsItsRawInputs() async throws {
        let session = try makeRecordingAwaitingMuxAndRetirement("Retire")
        let micURL = URL(fileURLWithPath: session.micAudioURL)
        let appURL = session.appAudioURL.map { URL(fileURLWithPath: $0) }

        try await deleteAndRestoreDuringAnotherMixdown(session)

        for url in RecordingSourceFiles.sourceURLs(micURL: micURL, appURL: appURL) {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test
    func testARecordingDeletedDuringAnotherMixdownStaysHeldAsItWas() async throws {
        let session = try makeRecordingAwaitingMuxAndRetirement("Held")
        let sessionID = session.id
        _ = try makeRecordingAwaitingMixdown("Blocker")
        let gate = JobGate()
        let muxed = OSAllocatedUnfairLock<[UUID]>(initialState: [])
        let recovery = makeRecovery(
            performMixdown: { _, _, _, _ in await gate.wait() },
            performMux: { request in muxed.withLock { $0.append(request.sessionID) } }
        )
        let sweep = Task { await recovery.sweepIncompleteSessions() }
        await gate.untilWaiting()

        #expect(await startDeleting(session).value == .deleted)
        let held = try contents(of: heldFolder(of: session))
        await gate.open()
        await sweep.value

        #expect(try stored(sessionID) == nil)
        #expect(try contents(of: heldFolder(of: session)) == held)
        #expect(!muxed.withLock { $0 }.contains(sessionID))
    }
}

/// Runs `onFirstCheck` the first time it is asked whether `path` exists, before answering.
private final class CheckpointFileManager: FileManager, @unchecked Sendable {
    private let path: String
    private let onFirstCheck: @Sendable () -> Void
    private let hasChecked = OSAllocatedUnfairLock(initialState: false)

    init(path: String, onFirstCheck: @escaping @Sendable () -> Void) {
        self.path = path
        self.onFirstCheck = onFirstCheck
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        if path == self.path, hasChecked.withLock({ checked in defer { checked = true }; return !checked }) {
            onFirstCheck()
        }
        return super.fileExists(atPath: path)
    }
}
