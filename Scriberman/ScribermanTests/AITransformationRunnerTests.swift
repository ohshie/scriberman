import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// The one runner every window and the extension API use to run a saved prompt on a session.
@MainActor
@Suite(.serialized)
final class AITransformationRunnerTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let suiteName = "AITransformationRunnerTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let promptStore: AIPromptStore
    private let aiService = MockAIProviderService()
    private let sessionJobs = SessionJobs()

    init() throws {
        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        promptStore = AIPromptStore(defaults: defaults)
        aiService.isEnabled = true
        aiService.isConfigured = true
        aiService.selectedModelID = "model-a"
        aiService.transformationResult = "Result text"
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Fixtures

    private func makeRunner() -> AITransformationRunner {
        AITransformationRunner(
            aiProviderService: aiService,
            promptStore: promptStore,
            sessionJobs: sessionJobs
        )
    }

    private func makeSavedSession(transcriptText: String? = "Transcript") throws -> RecordingSession {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            mixdownURL: "/tmp/mix.m4a",
            title: "Session",
            status: .done
        )
        if let transcriptText {
            session.transcript = Transcript(
                fullText: transcriptText,
                segments: [TranscriptSegment(speakerId: "S1", text: transcriptText, startTime: 0, endTime: 1, audioSource: .mic)],
                speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")]
            )
        }
        context.insert(session)
        try context.save()
        return session
    }

    /// The session's history as another context reads it from the store.
    private func savedHistory(of sessionID: UUID) throws -> [AITransformation] {
        let reader = ModelContext(container)
        let descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.id == sessionID })
        return try reader.fetch(descriptor).first?.aiTransformations ?? []
    }

    // MARK: - Tests

    @Test
    func testARunSavesTheResultAndSucceedsWithItsID() async throws {
        let session = try makeSavedSession()
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let runner = makeRunner()

        let operationID = try runner.start(prompt: prompt, on: session)
        let state = await runner.completion(of: operationID)

        let history = try savedHistory(of: session.id)
        #expect(history.count == 1)
        #expect(history.first?.resultText == "Result text")
        #expect(history.first?.promptName == "Summary")
        #expect(history.first?.modelID == "model-a")
        #expect(state == .succeeded(transformationID: try #require(history.first?.id)))
        #expect(runner.state(of: operationID) == state)
        #expect(promptStore.loadLastUsedPromptID() == prompt.id)
    }

    @Test
    func testTheRequestUsesTheModelSelectedWhenTheRunStarted() async throws {
        let session = try makeSavedSession()
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let runner = makeRunner()
        let release = holdRuns()

        let operationID = try runner.start(prompt: prompt, on: session)
        await waitForProviderCall()
        aiService.selectedModelID = "model-b"
        release()
        _ = await runner.completion(of: operationID)

        #expect(aiService.performedTransformations.map(\.modelID) == ["model-a"])
        #expect(try savedHistory(of: session.id).first?.modelID == "model-a")
    }

    @Test
    func testASecondCallerIsRefusedWhileTheSessionHasARunUnderWay() async throws {
        let session = try makeSavedSession()
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let runner = makeRunner()
        let release = holdRuns()

        let first = try runner.start(prompt: prompt, on: session)
        await waitForProviderCall()

        #expect(runner.isRunning(session.id))
        #expect(throws: AITransformationRunner.StartRefusal.alreadyRunning) {
            try runner.start(prompt: prompt, on: session)
        }

        release()
        _ = await runner.completion(of: first)

        #expect(runner.isRunning(session.id) == false)
        #expect(aiService.performedTransformations.count == 1)
        #expect(try savedHistory(of: session.id).count == 1)

        let second = try runner.start(prompt: prompt, on: session)
        _ = await runner.completion(of: second)
        #expect(try savedHistory(of: session.id).count == 2)
    }

    @Test
    func testAnotherSessionCanRunWhileOneIsRunning() async throws {
        let session = try makeSavedSession()
        let other = try makeSavedSession()
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let runner = makeRunner()
        let release = holdRuns()

        let first = try runner.start(prompt: prompt, on: session)
        await waitForProviderCall()
        let second = try runner.start(prompt: prompt, on: other)
        release()

        #expect(await runner.completion(of: first) != nil)
        #expect(await runner.completion(of: second) != nil)
        #expect(try savedHistory(of: other.id).count == 1)
    }

    @Test
    func testWithAIOffTheRunFailsAsNotConfiguredWithoutCallingTheProvider() async throws {
        aiService.isEnabled = false
        let session = try makeSavedSession()
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let runner = makeRunner()

        let operationID = try runner.start(prompt: prompt, on: session)
        let state = await runner.completion(of: operationID)

        #expect(state == .failed(.init(
            code: .aiNotConfigured,
            message: AIProviderService.AITransformationError.disabled.localizedDescription
        )))
        #expect(aiService.performedTransformations.isEmpty)
        #expect(try savedHistory(of: session.id).isEmpty)
        #expect(runner.isRunning(session.id) == false)
    }

    @Test
    func testWithoutAnAPIKeyTheRunFailsAsNotConfigured() async throws {
        aiService.isConfigured = false
        let session = try makeSavedSession()
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let runner = makeRunner()

        let operationID = try runner.start(prompt: prompt, on: session)

        #expect(await runner.completion(of: operationID) == .failed(.init(
            code: .aiNotConfigured,
            message: AIProviderService.AITransformationError.noAPIKeyConfigured.localizedDescription
        )))
        #expect(aiService.performedTransformations.isEmpty)
    }

    @Test
    func testWithoutAModelTheRunFailsAsNotConfigured() async throws {
        aiService.selectedModelID = nil
        let session = try makeSavedSession()
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let runner = makeRunner()

        let operationID = try runner.start(prompt: prompt, on: session)

        #expect(await runner.completion(of: operationID) == .failed(.init(
            code: .aiNotConfigured,
            message: AIProviderService.AITransformationError.noModelSelected.localizedDescription
        )))
        #expect(aiService.performedTransformations.isEmpty)
    }

    @Test
    func testWithoutATranscriptTheRunFailsAsNoTranscript() async throws {
        let session = try makeSavedSession(transcriptText: nil)
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let runner = makeRunner()

        let operationID = try runner.start(prompt: prompt, on: session)

        #expect(await runner.completion(of: operationID) == .failed(.init(
            code: .noTranscript,
            message: AIProviderService.AITransformationError.emptyTranscript.localizedDescription
        )))
        #expect(aiService.performedTransformations.isEmpty)
        #expect(try savedHistory(of: session.id).isEmpty)
    }

    @Test
    func testAProviderErrorFailsTheRunWithItsMessageAndSavesNothing() async throws {
        aiService.transformationError = TestError.expectedFailure
        let session = try makeSavedSession()
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let runner = makeRunner()

        let operationID = try runner.start(prompt: prompt, on: session)

        #expect(await runner.completion(of: operationID) == .failed(.init(
            code: .providerFailed,
            message: TestError.expectedFailure.localizedDescription
        )))
        #expect(try savedHistory(of: session.id).isEmpty)
        #expect(promptStore.loadLastUsedPromptID() == nil)
        #expect(runner.isRunning(session.id) == false)
    }

    @Test
    func testAProviderNotConfiguredErrorFailsAsNotConfigured() async throws {
        aiService.transformationError = AIProviderService.AITransformationError.noAPIKeyConfigured
        let session = try makeSavedSession()
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let runner = makeRunner()

        let operationID = try runner.start(prompt: prompt, on: session)

        #expect(await runner.completion(of: operationID) == .failed(.init(
            code: .aiNotConfigured,
            message: AIProviderService.AITransformationError.noAPIKeyConfigured.localizedDescription
        )))
    }

    @Test
    func testASessionDeletedDuringTheRunGetsNothingWritten() async throws {
        let session = try makeSavedSession()
        let sessionID = session.id
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let runner = makeRunner()
        _ = holdRuns()

        let operationID = try runner.start(prompt: prompt, on: session)
        await waitForProviderCall()

        // A delete that is undone: the record stays, but the run started before it.
        await sessionJobs.startDeleting(sessionID)
        sessionJobs.finishDeleting(sessionID)
        let state = await runner.completion(of: operationID)

        #expect(state == .failed(.init(code: .notFound, message: nil)))
        #expect(try savedHistory(of: sessionID).isEmpty)
        #expect(promptStore.loadLastUsedPromptID() == nil)
        #expect(runner.isRunning(sessionID) == false)
    }

    @Test
    func testAnUnknownOperationHasNoState() async {
        let runner = makeRunner()
        let unknown = UUID()

        #expect(runner.state(of: unknown) == nil)
        #expect(await runner.completion(of: unknown) == nil)
    }

    // MARK: - Holding a run open

    private enum TestError: LocalizedError {
        case expectedFailure

        var errorDescription: String? { "Expected failure" }
    }

    /// Holds every provider call until the returned closure is called, or the run is cancelled.
    private func holdRuns() -> () -> Void {
        let (gate, release) = AsyncStream<Void>.makeStream()
        aiService.transformationGate = {
            for await _ in gate { break }
        }
        return {
            release.yield()
            release.finish()
        }
    }

    private func waitForProviderCall() async {
        for _ in 0..<10_000 where aiService.performedTransformations.isEmpty {
            await Task.yield()
        }
    }
}
