import Foundation
import SwiftData
import Testing
import os
@testable import Scriberman

/// Deleting a recording while it is finalized, mixed down or muxed.
@MainActor
final class RecordingPipelineDeletionTests {
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

    private lazy var folder = workspace.recordingsURL.appendingPathComponent("Recording A", isDirectory: true)
    private var micURL: URL { folder.appendingPathComponent("mic.wav") }
    private var appURL: URL { folder.appendingPathComponent("app.wav") }
    private var mixdownURL: URL { folder.appendingPathComponent("recording.m4a") }
    private var screenTmpURL: URL { folder.appendingPathComponent("screen-tmp.mov") }
    private var screenVideoURL: URL { folder.appendingPathComponent("screen.mov") }
    private var heldFolder: URL { HoldingFolder(workspace: workspace).heldFolder(for: sessionID) }
    private var sessionID = UUID()

    /// A recording as `RecordingService.stopRecording` leaves it: raw inputs and the temporary
    /// screen video on disk, status recorded, mux pending.
    private func makeRecording(status: RecordingStatus = .recorded, withRawInputs: Bool = true) throws -> RecordingSession {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if withRawInputs {
            for url in RecordingSourceFiles.sourceURLs(micURL: micURL, appURL: appURL) {
                try Data("raw \(url.lastPathComponent)".utf8).write(to: url)
            }
        }
        try Data("screen tmp".utf8).write(to: screenTmpURL)
        let session = RecordingSession(
            duration: 60,
            micAudioURL: micURL.path,
            appAudioURL: appURL.path,
            title: "A",
            status: status
        )
        session.screenMuxState = ScreenMuxState.pending.rawValue
        context.insert(session)
        try context.save()
        sessionID = session.id
        return session
    }

    private func storedRecording() throws -> RecordingSession? {
        try RecordingSession.fetch(id: sessionID, in: ModelContext(container))
    }

    private func heldSnapshot() throws -> RecordingSessionRecord {
        let snapshot = try SessionSnapshot.read(from: heldFolder)
        guard case .recording(let record) = snapshot.session else {
            Issue.record("The held snapshot is not a recording.")
            throw CancellationError()
        }
        return record
    }

    private func fileNames(in folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
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

    /// Checks that a delete started on the session is waiting: the session is off the list, and
    /// nothing has moved or been deleted yet.
    private func expectDeleteIsWaiting() async throws {
        try await eventually { self.coordinator.isRemoving(self.sessionID) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.isRemoving(sessionID))
        #expect(try storedRecording() != nil)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(!FileManager.default.fileExists(atPath: heldFolder.path))
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

    private func finalizationJob() -> RecordingFinalizationJob {
        RecordingFinalizationJob(
            sessionID: sessionID,
            micURL: micURL,
            appURL: appURL,
            mixdownURL: mixdownURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 2_000),
            timelineMixdown: false,
            screenMux: muxRequest()
        )
    }

    private func muxRequest() -> ScreenVideoMuxRequest {
        ScreenVideoMuxRequest(
            sessionID: sessionID,
            screenTmpURL: screenTmpURL,
            screenVideoURL: screenVideoURL,
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 2_000),
            videoStartHostTime: HostNanoseconds(nanoseconds: 1_500)
        )
    }

    // MARK: - Finalizer

    @Test
    func testDeleteDuringFinalizationWaitsForItAndKeepsTheRawInputs() async throws {
        let session = try makeRecording()
        let gate = JobGate()
        let finalizer = RecordingFinalizer(
            mixdownCoordinator: UninterruptibleMixdown(gate: gate),
            screenVideoMuxer: NoOpMuxer(),
            sessionJobs: jobs
        )
        await finalizer.schedule(finalizationJob())
        await gate.untilWaiting()

        let deletion = startDeleting(session)
        try await expectDeleteIsWaiting()
        await gate.open()

        #expect(await deletion.value == .deleted)
        #expect(await finalizer.waitForAll(timeout: .seconds(10)))
        #expect(!coordinator.isRemoving(sessionID))
        #expect(try storedRecording() == nil)
        for url in RecordingSourceFiles.sourceURLs(micURL: micURL, appURL: appURL) {
            #expect(FileManager.default.fileExists(atPath: heldFolder.appendingPathComponent(url.lastPathComponent).path))
        }
    }

    @Test
    func testUndoAfterADeleteDuringFinalizationRestoresTheRecordingAsItWas() async throws {
        let session = try makeRecording()
        let files = try contents(of: folder)
        let gate = JobGate()
        let finalizer = RecordingFinalizer(
            mixdownCoordinator: UninterruptibleMixdown(gate: gate),
            screenVideoMuxer: NoOpMuxer(),
            sessionJobs: jobs
        )
        await finalizer.schedule(finalizationJob())
        await gate.untilWaiting()

        let deletion = startDeleting(session)
        try await expectDeleteIsWaiting()
        await gate.open()
        #expect(await deletion.value == .deleted)
        await undo()
        #expect(await finalizer.waitForAll(timeout: .seconds(10)))

        let restored = try #require(try storedRecording())
        #expect(restored.status == .recorded)
        #expect(restored.mixdownURL == nil)
        #expect(restored.screenMuxState == ScreenMuxState.pending.rawValue)
        #expect(try contents(of: folder) == files)
    }

    // MARK: - Mixdown

    private func makeMixdownCoordinator(gate: JobGate) -> RecordingMixdownCoordinator {
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        // The first read fails and the retry waits on the gate: an uninterruptible step.
        let reader = AudioSampleReader(
            avAudioFileRead: { _ in
                let attempt = attempts.withLock { count in
                    count += 1
                    return count
                }
                guard attempt > 1 else { throw RecordingError.failedToStart("held for the test") }
                return Array(repeating: 0.25, count: 4_800)
            },
            extAudioFileRead: { _, _ in throw RecordingError.failedToStart("held for the test") },
            sleep: { _ in await gate.wait() }
        )
        return RecordingMixdownCoordinator(
            workspaceService: workspaceService,
            modelContainer: container,
            mixdownService: AudioMixdownService(sampleReader: reader),
            sessionJobs: jobs
        )
    }

    private func startMixdown(_ coordinator: RecordingMixdownCoordinator) -> Task<Bool, Never> {
        let request = finalizationJob()
        return Task {
            await coordinator.runMixdown(
                sessionID: request.sessionID,
                micURL: request.micURL,
                appURL: nil,
                mixdownURL: request.mixdownURL,
                micStartHostTime: request.micStartHostTime,
                appStartHostTime: nil,
                timelineMixdown: false
            )
        }
    }

    @Test
    func testDeleteDuringMixdownWaitsItOutAndSavesNoMixdown() async throws {
        let session = try makeRecording()
        let gate = JobGate()
        let mixdown = startMixdown(makeMixdownCoordinator(gate: gate))
        await gate.untilWaiting()

        let deletion = startDeleting(session)
        try await expectDeleteIsWaiting()
        await gate.open()

        #expect(await deletion.value == .deleted)
        #expect(await mixdown.value == false)
        #expect(try heldSnapshot().mixdownURL == nil)
        #expect(FileManager.default.fileExists(atPath: heldFolder.appendingPathComponent("mic.wav").path))
    }

    @Test
    func testUndoAfterADeleteDuringMixdownRestoresTheRecordingWithoutAMixdown() async throws {
        let session = try makeRecording()
        let gate = JobGate()
        let mixdown = startMixdown(makeMixdownCoordinator(gate: gate))
        await gate.untilWaiting()

        let deletion = startDeleting(session)
        try await expectDeleteIsWaiting()
        await gate.open()
        #expect(await deletion.value == .deleted)
        let held = try contents(of: heldFolder).filter { $0.key != SessionSnapshot.fileName }
        await undo()
        _ = await mixdown.value

        let restored = try #require(try storedRecording())
        #expect(restored.mixdownURL == nil)
        #expect(restored.status == .recorded)
        #expect(try contents(of: folder) == held)
    }

    // MARK: - Screen mux

    private func makeMuxer(exporter: any ScreenVideoExporting) -> ScreenVideoMuxer {
        ScreenVideoMuxer(
            workspaceService: workspaceService,
            modelContainer: container,
            exporter: exporter,
            sessionJobs: jobs
        )
    }

    private func startMux(_ muxer: ScreenVideoMuxer) -> Task<Void, Never> {
        let request = muxRequest()
        return Task { await muxer.runMux(request: request) }
    }

    @Test
    func testDeleteDuringMuxCancelsTheExportAndWritesNothing() async throws {
        let session = try makeRecording()
        let gate = JobGate()
        let mux = startMux(makeMuxer(exporter: GatedExporter(gate: gate, honoursCancellation: true)))
        await gate.untilWaiting()

        // The gate never opens: only cancelling the export lets the delete finish.
        #expect(await startDeleting(session).value == .deleted)
        await mux.value

        let record = try heldSnapshot()
        #expect(record.screenVideoURL == nil)
        #expect(record.screenMuxState == ScreenMuxState.pending.rawValue)
        #expect(try fileNames(in: heldFolder).contains("screen-tmp.mov"))
        #expect(!(try fileNames(in: heldFolder).contains("screen.mov")))
    }

    @Test
    func testDeleteDuringAnExportThatCannotBeCancelledWaitsForItAndSavesNothing() async throws {
        let session = try makeRecording()
        let gate = JobGate()
        let mux = startMux(makeMuxer(exporter: GatedExporter(gate: gate, honoursCancellation: false)))
        await gate.untilWaiting()

        let deletion = startDeleting(session)
        try await expectDeleteIsWaiting()
        await gate.open()

        #expect(await deletion.value == .deleted)
        await mux.value
        let record = try heldSnapshot()
        #expect(record.screenVideoURL == nil)
        #expect(record.screenMuxState == ScreenMuxState.pending.rawValue)
        #expect(try fileNames(in: heldFolder).contains("screen-tmp.mov"))
    }

    @Test
    func testUndoAfterADeleteDuringMuxRestoresTheRecordingWithItsMuxPending() async throws {
        let session = try makeRecording()
        let files = try contents(of: folder)
        let gate = JobGate()
        let mux = startMux(makeMuxer(exporter: GatedExporter(gate: gate, honoursCancellation: true)))
        await gate.untilWaiting()

        #expect(await startDeleting(session).value == .deleted)
        await undo()
        await gate.open()
        await mux.value

        let restored = try #require(try storedRecording())
        #expect(restored.screenVideoURL == nil)
        #expect(restored.screenMuxState == ScreenMuxState.pending.rawValue)
        #expect(try contents(of: folder) == files)
    }

    // MARK: - Status

    @Test
    func testAConvertingRecordingIsHeldAsRecordedWhenItsRawInputsExist() async throws {
        let session = try makeRecording(status: .converting)

        #expect(await coordinator.delete(session, context: context, undoManager: undoManager) == .deleted)
        #expect(try heldSnapshot().statusRawValue == RecordingStatus.recorded.persistedValue)
        await undo()

        let restored = try #require(try storedRecording())
        #expect(restored.status == .recorded)
        let availability = SessionCommandAvailability(
            selection: .recording(restored.status, isTrimmed: false),
            isRecordingRunning: false,
            isTranscriptShown: false,
            hasLoadedAudio: false,
            hasFindTarget: false,
            isSelectionInActiveWorkspace: true
        )
        #expect(availability.isEnabled(.transcribe))
    }

    @Test
    func testAConvertingRecordingWithoutRawInputsIsHeldAsConverting() async throws {
        let session = try makeRecording(status: .converting, withRawInputs: false)

        #expect(await coordinator.delete(session, context: context, undoManager: undoManager) == .deleted)

        #expect(try heldSnapshot().statusRawValue == RecordingStatus.converting.persistedValue)
    }

    // MARK: - List

    @Test
    func testADeleteThatFailsListsTheSessionAgain() async throws {
        let session = try makeRecording()
        workspaceService.currentWorkspaceResult = nil

        #expect(await coordinator.delete(session, context: context, undoManager: undoManager) == .moveFailed)

        #expect(!coordinator.isRemoving(sessionID))
        #expect(try storedRecording() != nil)
    }
}

// MARK: - Fakes

/// A mixdown that ignores cancellation, reports success and writes nothing.
private actor UninterruptibleMixdown: RecordingMixdownCoordinating {
    let gate: JobGate

    init(gate: JobGate) {
        self.gate = gate
    }

    func runMixdown(
        sessionID _: UUID,
        micURL _: URL,
        appURL _: URL?,
        mixdownURL _: URL,
        micStartHostTime _: HostNanoseconds,
        appStartHostTime _: HostNanoseconds?,
        timelineMixdown _: Bool
    ) async -> Bool {
        await gate.wait()
        return true
    }
}

private struct NoOpMuxer: ScreenVideoMuxing {
    func runMux(request _: ScreenVideoMuxRequest) async {}
}

/// Waits on the gate, then writes the screen video.
private struct GatedExporter: ScreenVideoExporting {
    let gate: JobGate
    let honoursCancellation: Bool

    func export(plan: ScreenVideoMuxPlan) async throws {
        if honoursCancellation {
            if await gate.waitCancellably() { throw CancellationError() }
        } else {
            await gate.wait()
        }
        _ = FileManager.default.createFile(atPath: plan.request.screenVideoURL.path, contents: Data("screen".utf8))
    }
}
