import Foundation
import OpenAI
import SwiftData
import Testing
@testable import Scriberman

/// Deleting a recording while it is transcribed, retranscribed or transformed.
@MainActor
final class TranscriptionDeletionTests {
    private let workspace: Workspace
    private let workspaceService = MockWorkspaceService()
    private let container: ModelContainer
    private let context: ModelContext
    private let undoManager = UndoManager.forTests()
    private let jobs = SessionJobs()
    private let defaultsSuiteName = "TranscriptionDeletionTests.\(UUID().uuidString)"
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
        workspaceService.requireWritableResult = .success(workspace)
        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    deinit {
        try? FileManager.default.removeItem(at: workspace.rootURL)
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
    }

    // MARK: - Fixtures

    private lazy var folder = workspace.recordingsURL.appendingPathComponent("Recording A", isDirectory: true)
    private var micURL: URL { folder.appendingPathComponent("mic.wav") }
    private var mixdownURL: URL { folder.appendingPathComponent("recording.m4a") }
    private var heldFolder: URL { HoldingFolder(workspace: workspace).heldFolder(for: sessionID) }
    private var sessionID = UUID()

    /// A mixed-down recording, with a transcript when `transcriptText` is given.
    private func makeRecording(status: RecordingStatus, transcriptText: String? = nil) throws -> RecordingSession {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mic".utf8).write(to: micURL)
        try Data("mixdown".utf8).write(to: mixdownURL)
        let session = RecordingSession(
            duration: 60,
            micAudioURL: micURL.path,
            title: "A",
            status: status
        )
        session.mixdownURL = mixdownURL.path
        if let transcriptText {
            session.transcript = Self.transcript(transcriptText)
        }
        context.insert(session)
        try context.save()
        sessionID = session.id
        return session
    }

    private static func transcript(_ text: String) -> Transcript {
        Transcript(
            fullText: text,
            segments: [TranscriptSegment(speakerId: "S1", text: text, startTime: 0, endTime: 1, audioSource: .mic)],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")]
        )
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

    private func availability(of session: RecordingSession) -> SessionCommandAvailability {
        SessionCommandAvailability(
            selection: .recording(session.status, isTrimmed: false),
            isRecordingRunning: false,
            isTranscriptShown: session.displayedTranscript != nil,
            hasLoadedAudio: true,
            hasFindTarget: false,
            isSelectionInActiveWorkspace: true
        )
    }

    // MARK: - Transcription

    private func makeJobsViewModel(
        transcription: any TranscriptionServiceProtocol = MockTranscriptionService(),
        retranscription: RetranscriptionService? = nil
    ) -> JobsViewModel {
        let retranscriptionService = retranscription
            ?? RetranscriptionService(transcriptionService: TranscriptionService(), sessionJobs: jobs)
        return JobsViewModel(
            workspaceService: workspaceService,
            transcriptionService: transcription,
            retranscriptionService: retranscriptionService,
            audioImportService: AudioImportService(retranscriptionService: retranscriptionService),
            sessionJobs: jobs
        )
    }

    @Test
    func testDeleteDuringTranscriptionCancelsItAndHoldsTheRecordingAsRecorded() async throws {
        let session = try makeRecording(status: .recorded)
        let gate = JobGate()
        let viewModel = makeJobsViewModel(transcription: GatedTranscription(gate: gate, honoursCancellation: true))
        viewModel.transcribe(session: session, context: context)
        await gate.untilWaiting()

        // The gate never opens: only cancelling the transcription lets the delete finish.
        #expect(await startDeleting(session).value == .deleted)

        let record = try heldSnapshot()
        #expect(record.statusRawValue == RecordingStatus.recorded.persistedValue)
        #expect(record.transcriptData == nil)
        #expect(record.errorMessage == nil)
        #expect(try storedRecording() == nil)
    }

    @Test
    func testDeleteDuringATranscriptionThatCannotBeCancelledWaitsForItAndSavesNothing() async throws {
        let session = try makeRecording(status: .recorded)
        let gate = JobGate()
        let viewModel = makeJobsViewModel(transcription: GatedTranscription(gate: gate, honoursCancellation: false))
        viewModel.transcribe(session: session, context: context)
        await gate.untilWaiting()

        let deletion = startDeleting(session)
        try await expectDeleteIsWaiting()
        await gate.open()

        #expect(await deletion.value == .deleted)
        let record = try heldSnapshot()
        #expect(record.statusRawValue == RecordingStatus.recorded.persistedValue)
        #expect(record.transcriptData == nil)
    }

    @Test
    func testUndoAfterADeleteDuringTranscriptionRestoresTheRecordingReadyToTranscribe() async throws {
        let session = try makeRecording(status: .recorded)
        let files = try contents(of: folder)
        let gate = JobGate()
        let viewModel = makeJobsViewModel(transcription: GatedTranscription(gate: gate, honoursCancellation: true))
        viewModel.transcribe(session: session, context: context)
        await gate.untilWaiting()

        #expect(await startDeleting(session).value == .deleted)
        await undo()
        await gate.open()
        try await Task.sleep(for: .milliseconds(100))

        let restored = try #require(try storedRecording())
        #expect(restored.status == .recorded)
        #expect(restored.transcript == nil)
        #expect(restored.errorMessage == nil)
        #expect(try contents(of: folder) == files)
        #expect(availability(of: restored).isEnabled(.transcribe))
    }

    // MARK: - Retranscription

    private func makeRetranscriptionService(gate: JobGate, honoursCancellation: Bool) -> RetranscriptionService {
        RetranscriptionService(
            transcriptionService: TranscriptionService(),
            extractSamples: { _ in (mic: [0.1, 0.2], app: nil) },
            prepareModelsHandler: { _ in },
            transcribePassFromSamplesHandler: { _, _, _, _, _ in
                if honoursCancellation {
                    if await gate.waitCancellably() { throw CancellationError() }
                } else {
                    await gate.wait()
                }
                return TranscriptionPassRunner.PassResult(segments: [
                    TranscriptSegment(speakerId: "S1", text: "late", startTime: 0, endTime: 1, audioSource: .mic)
                ])
            },
            sessionJobs: jobs
        )
    }

    @Test
    func testDeleteDuringReprocessCancelsItAndHoldsTheRecordingAsDone() async throws {
        let session = try makeRecording(status: .done, transcriptText: "first")
        let gate = JobGate()
        let viewModel = makeJobsViewModel(
            retranscription: makeRetranscriptionService(gate: gate, honoursCancellation: true)
        )
        viewModel.reprocess(session: session, context: context)
        await gate.untilWaiting()

        #expect(await startDeleting(session).value == .deleted)

        let record = try heldSnapshot()
        #expect(record.statusRawValue == RecordingStatus.done.persistedValue)
        #expect(record.retranscriptData == nil)
        #expect(record.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: heldFolder.appendingPathComponent("transcript.md").path))
        try await eventually { !viewModel.isRetranscribing }
    }

    @Test
    func testDeleteDuringARetranscriptionThatCannotBeCancelledWaitsForItAndWritesNothing() async throws {
        let session = try makeRecording(status: .retranscribing, transcriptText: "first")
        let gate = JobGate()
        let service = makeRetranscriptionService(gate: gate, honoursCancellation: false)
        let sessionID = sessionID
        let container = container
        let workspace = workspace
        let retranscription = Task {
            await service.retranscribe(sessionID: sessionID, modelContainer: container, workspace: workspace)
        }
        await gate.untilWaiting()

        let deletion = startDeleting(session)
        try await expectDeleteIsWaiting()
        await gate.open()

        #expect(await deletion.value == .deleted)
        await retranscription.value
        let record = try heldSnapshot()
        #expect(record.statusRawValue == RecordingStatus.done.persistedValue)
        #expect(record.retranscriptData == nil)
        #expect(!FileManager.default.fileExists(atPath: heldFolder.appendingPathComponent("transcript.md").path))
    }

    @Test
    func testUndoAfterADeleteDuringReprocessRestoresTheRecordingReadyToReprocess() async throws {
        let session = try makeRecording(status: .done, transcriptText: "first")
        let files = try contents(of: folder)
        let gate = JobGate()
        let viewModel = makeJobsViewModel(
            retranscription: makeRetranscriptionService(gate: gate, honoursCancellation: true)
        )
        viewModel.reprocess(session: session, context: context)
        await gate.untilWaiting()

        #expect(await startDeleting(session).value == .deleted)
        await undo()
        await gate.open()
        try await eventually { !viewModel.isRetranscribing }

        let restored = try #require(try storedRecording())
        #expect(restored.status == .done)
        #expect(restored.retranscript == nil)
        #expect(restored.transcript?.fullText == "first")
        #expect(restored.errorMessage == nil)
        #expect(try contents(of: folder) == files)
        #expect(availability(of: restored).isEnabled(.reprocess))
    }

    // MARK: - AI transformation

    private func makeTransformationViewModel(
        session: RecordingSession,
        gate: JobGate,
        honoursCancellation: Bool
    ) -> TranscriptDetailViewModel {
        let defaults = UserDefaults(suiteName: defaultsSuiteName) ?? .standard
        let keychainStore = MockKeychainStore()
        try? keychainStore.save(key: "aiProvider.openAI.apiKey", value: "sk-12345678901234567890")
        let service = AIProviderService(
            keychainStore: keychainStore,
            store: AIProviderStore(defaults: defaults),
            responseCreator: { _, _ in
                if honoursCancellation {
                    if await gate.waitCancellably() { throw CancellationError() }
                } else {
                    await gate.wait()
                }
                return try TranscriptDetailViewModelTests.makeResponse(text: "late")
            }
        )
        service.isEnabled = true
        service.selectedModelID = "gpt-5.2"
        return TranscriptDetailViewModel(
            session: session,
            aiProviderService: service,
            promptStore: AIPromptStore(defaults: defaults),
            sessionJobs: jobs
        )
    }

    private func startTransformation(_ viewModel: TranscriptDetailViewModel, of session: RecordingSession) -> Task<Void, Never> {
        let request = AITransformationRequest(
            transcript: "first",
            systemPrompt: "Summarize",
            promptName: "Summary",
            modelID: "gpt-5.2"
        )
        return Task { await viewModel.runTransformation(request, session: session, promptID: nil) }
    }

    @Test
    func testDeleteDuringTransformationCancelsItAndSavesNoResult() async throws {
        let session = try makeRecording(status: .done, transcriptText: "first")
        let gate = JobGate()
        let viewModel = makeTransformationViewModel(session: session, gate: gate, honoursCancellation: true)
        let transformation = startTransformation(viewModel, of: session)
        await gate.untilWaiting()

        #expect(await startDeleting(session).value == .deleted)
        await transformation.value

        #expect(try heldSnapshot().aiTransformationsData == nil)
        #expect(viewModel.transformationErrorMessage == nil)
        #expect(!viewModel.isRunningTransformation)
    }

    @Test
    func testDeleteDuringATransformationThatCannotBeCancelledWaitsForItAndSavesNoResult() async throws {
        let session = try makeRecording(status: .done, transcriptText: "first")
        let gate = JobGate()
        let viewModel = makeTransformationViewModel(session: session, gate: gate, honoursCancellation: false)
        let transformation = startTransformation(viewModel, of: session)
        await gate.untilWaiting()

        let deletion = startDeleting(session)
        try await expectDeleteIsWaiting()
        await gate.open()

        #expect(await deletion.value == .deleted)
        await transformation.value
        #expect(try heldSnapshot().aiTransformationsData == nil)
        #expect(viewModel.selectedTransformationID == nil)
    }

    @Test
    func testUndoAfterADeleteDuringTransformationRestoresTheRecordingWithoutTheResult() async throws {
        let session = try makeRecording(status: .done, transcriptText: "first")
        let gate = JobGate()
        let viewModel = makeTransformationViewModel(session: session, gate: gate, honoursCancellation: true)
        let transformation = startTransformation(viewModel, of: session)
        await gate.untilWaiting()

        #expect(await startDeleting(session).value == .deleted)
        await undo()
        await gate.open()
        await transformation.value
        try context.save()

        let restored = try #require(try storedRecording())
        #expect(restored.aiTransformations.isEmpty)
        #expect(restored.status == .done)
    }

    // MARK: - Status

    @Test
    func testATranscribingRecordingIsHeldAsRecordedAndRestoredReadyToTranscribe() async throws {
        let session = try makeRecording(status: .transcribing)

        #expect(await coordinator.delete(session, context: context, undoManager: undoManager) == .deleted)
        #expect(try heldSnapshot().statusRawValue == RecordingStatus.recorded.persistedValue)
        await undo()

        let restored = try #require(try storedRecording())
        #expect(restored.status == .recorded)
        #expect(availability(of: restored).isEnabled(.transcribe))
    }

    @Test
    func testARetranscribingRecordingWithATranscriptIsHeldAsDoneAndRestoredReadyToReprocess() async throws {
        let session = try makeRecording(status: .retranscribing, transcriptText: "first")

        #expect(await coordinator.delete(session, context: context, undoManager: undoManager) == .deleted)
        #expect(try heldSnapshot().statusRawValue == RecordingStatus.done.persistedValue)
        await undo()

        let restored = try #require(try storedRecording())
        #expect(restored.status == .done)
        #expect(availability(of: restored).isEnabled(.reprocess))
    }

    @Test
    func testARetranscribingRecordingWithoutATranscriptIsHeldAsRecordedAndRestoredReadyToTranscribe() async throws {
        let session = try makeRecording(status: .retranscribing)

        #expect(await coordinator.delete(session, context: context, undoManager: undoManager) == .deleted)
        #expect(try heldSnapshot().statusRawValue == RecordingStatus.recorded.persistedValue)
        await undo()

        let restored = try #require(try storedRecording())
        #expect(restored.status == .recorded)
        #expect(availability(of: restored).isEnabled(.transcribe))
        #expect(availability(of: restored).isEnabled(.reprocess))
    }
}

// MARK: - Fakes

/// Waits on the gate, then returns a transcript.
private struct GatedTranscription: TranscriptionServiceProtocol {
    let gate: JobGate
    let honoursCancellation: Bool

    func transcribe(
        sessionID _: UUID,
        modelContainer _: ModelContainer,
        workspace _: Workspace,
        pipelineSettings _: LiveTranscriptionPipelineSettings
    ) async throws -> Transcript {
        if honoursCancellation {
            if await gate.waitCancellably() { throw CancellationError() }
        } else {
            await gate.wait()
        }
        return Transcript(
            fullText: "late",
            segments: [TranscriptSegment(speakerId: "S1", text: "late", startTime: 0, endTime: 1, audioSource: .mic)],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")]
        )
    }
}
