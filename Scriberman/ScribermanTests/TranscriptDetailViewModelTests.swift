import Foundation
import OpenAI
import Testing
@testable import Scriberman

struct TranscriptDetailViewModelTests {
    private enum TestError: LocalizedError {
        case expectedFailure

        var errorDescription: String? {
            "Expected failure"
        }
    }

    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "TranscriptDetailViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func cleanupDefaults(named suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test
    @MainActor
    func testLoadPromptsSortsAlphabeticallyAndRestoresLastUsedSelection() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let promptStore = AIPromptStore(defaults: defaults)
        let alpha = promptStore.addPrompt(name: "alpha", content: "A")
        _ = promptStore.addPrompt(name: "zeta", content: "Z")
        _ = promptStore.addPrompt(name: "Beta", content: "B")
        promptStore.setLastUsedPromptID(alpha.id)

        let viewModel = TranscriptDetailViewModel(
            session: makeRecordingSession(),
            aiProviderService: makeService(defaults: defaults),
            promptStore: promptStore
        )

        viewModel.loadPrompts()

        #expect(viewModel.prompts.map { $0.name } == ["alpha", "Beta", "zeta"])
        #expect(viewModel.selectedPromptID == alpha.id)
    }

    @Test
    @MainActor
    func testRunTransformationSuccessTogglesRunningAndAppendsResult() async {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let promptStore = AIPromptStore(defaults: defaults)
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let session = makeRecordingSession(transcriptText: "Transcript")

        let service = makeService(
            defaults: defaults,
            responseCreator: { _, _ in
                try await Task.sleep(nanoseconds: 120_000_000)
                return try Self.makeResponse(text: "Result text")
            }
        )
        service.selectedModelID = "gpt-5.2"

        let viewModel = TranscriptDetailViewModel(
            session: session,
            aiProviderService: service,
            promptStore: promptStore
        )
        viewModel.prompts = [prompt]
        viewModel.selectedPromptID = prompt.id

        let task = Task {
            await viewModel.runTransformation()
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(viewModel.isRunningTransformation)

        await task.value

        #expect(viewModel.isRunningTransformation == false)
        #expect(viewModel.transformationErrorMessage == nil)
        #expect(session.aiTransformations.count == 1)
        #expect(session.aiTransformations.first?.resultText == "Result text")
        #expect(session.aiTransformations.first?.promptName == "Summary")
        #expect(viewModel.selectedTransformationID == session.aiTransformations.first?.id)
        #expect(promptStore.loadLastUsedPromptID() == prompt.id)
    }

    @Test
    @MainActor
    func testRunTransformationErrorSurfacesMessageAndResetsRunning() async {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let promptStore = AIPromptStore(defaults: defaults)
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let session = makeRecordingSession(transcriptText: "Transcript")

        let service = makeService(
            defaults: defaults,
            responseCreator: { _, _ in
                throw TestError.expectedFailure
            }
        )
        service.selectedModelID = "gpt-5.2"

        let viewModel = TranscriptDetailViewModel(
            session: session,
            aiProviderService: service,
            promptStore: promptStore
        )
        viewModel.prompts = [prompt]
        viewModel.selectedPromptID = prompt.id

        await viewModel.runTransformation()

        #expect(viewModel.isRunningTransformation == false)
        #expect(viewModel.transformationErrorMessage != nil)
        #expect(session.aiTransformations.count == 0)
    }

    @Test
    @MainActor
    func testDerivedSessionProperties() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let session = makeRecordingSession(
            transcriptText: "Original",
            retranscriptText: "Retranscript",
            capturedAppName: "Zoom",
            status: .retranscribing,
            mixdownURL: "/tmp/mix.m4a"
        )

        let oldTransformation = AITransformation(
            promptName: "Old",
            modelID: "gpt-5.2",
            resultText: "Old result",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let newTransformation = AITransformation(
            promptName: "New",
            modelID: "gpt-5.2",
            resultText: "New result",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        session.aiTransformations = [newTransformation, oldTransformation]

        let viewModel = TranscriptDetailViewModel(
            session: session,
            aiProviderService: makeService(defaults: defaults)
        )

        #expect(viewModel.displayedTranscript?.fullText == "Retranscript")
        #expect(viewModel.finalTranscriptText == "Retranscript")
        #expect(viewModel.originalTranscriptText == "Original")
        #expect(viewModel.applicationName == "Zoom")
        #expect(viewModel.availableTransformations.map { $0.promptName } == ["Old", "New"])
        #expect(viewModel.canReprocess == false)
        #expect(viewModel.isReprocessing)
        #expect(viewModel.isReprocessed)
    }

    @MainActor
    private func makeService(
        defaults: UserDefaults,
        responseCreator: ((OpenAI, CreateModelResponseQuery) async throws -> ResponseObject)? = nil
    ) -> AIProviderService {
        let keychainStore = MockKeychainStore()
        try? keychainStore.save(key: "aiProvider.openAI.apiKey", value: "sk-12345678901234567890")
        let creator = responseCreator ?? { _, _ in
            try Self.makeResponse(text: "OK")
        }

        return AIProviderService(
            keychainStore: keychainStore,
            store: AIProviderStore(defaults: defaults),
            responseCreator: creator
        )
    }

    private func makeRecordingSession(
        transcriptText: String? = "Transcript",
        retranscriptText: String? = nil,
        capturedAppName: String? = nil,
        status: RecordingStatus = .done,
        mixdownURL: String? = "/tmp/mix.m4a"
    ) -> RecordingSession {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            mixdownURL: mixdownURL,
            title: "Session",
            capturedAppName: capturedAppName,
            status: status
        )

        if let transcriptText {
            session.transcript = Transcript(
                fullText: transcriptText,
                segments: [TranscriptSegment(speakerId: "S1", text: transcriptText, startTime: 0, endTime: 1, audioSource: .mic)],
                speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")]
            )
        }

        if let retranscriptText {
            session.retranscript = Transcript(
                fullText: retranscriptText,
                segments: [TranscriptSegment(speakerId: "S2", text: retranscriptText, startTime: 0, endTime: 1, audioSource: .app)],
                speakers: [TranscriptSpeaker(id: "S2", label: "Speaker 2", colorHex: "#222222")]
            )
        }

        return session
    }

    private static func makeResponse(text: String) throws -> ResponseObject {
        let payload = """
        {
          "created_at": 123,
          "error": null,
          "id": "resp_1",
          "incomplete_details": null,
          "instructions": null,
          "max_output_tokens": null,
          "metadata": {},
          "model": "gpt-5.2",
          "object": "response",
          "output": [
            {
              "id": "msg_1",
              "type": "message",
              "role": "assistant",
              "content": [
                {
                  "type": "output_text",
                  "text": "\(text)",
                  "annotations": [],
                  "logprobs": []
                }
              ],
              "status": "completed"
            }
          ],
          "parallel_tool_calls": false,
          "previous_response_id": null,
          "reasoning": null,
          "status": "completed",
          "temperature": null,
          "text": { "format": null },
          "tool_choice": "auto",
          "tools": [],
          "top_p": null,
          "truncation": null,
          "usage": null,
          "user": null
        }
        """

        let data = Data(payload.utf8)
        return try JSONDecoder().decode(ResponseObject.self, from: data)
    }
}
