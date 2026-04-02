import Foundation
import OpenAI
import XCTest
@testable import Scriberman

@MainActor
final class TranscriptDetailViewModelTests: XCTestCase {
    private enum TestError: LocalizedError {
        case expectedFailure

        var errorDescription: String? {
            "Expected failure"
        }
    }

    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TranscriptDetailViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadPromptsSortsAlphabeticallyAndRestoresLastUsedSelection() {
        let promptStore = AIPromptStore(defaults: defaults)
        let alpha = promptStore.addPrompt(name: "alpha", content: "A")
        _ = promptStore.addPrompt(name: "zeta", content: "Z")
        _ = promptStore.addPrompt(name: "Beta", content: "B")
        promptStore.setLastUsedPromptID(alpha.id)

        let viewModel = TranscriptDetailViewModel(
            session: makeRecordingSession(),
            aiProviderService: makeService(),
            promptStore: promptStore
        )

        viewModel.loadPrompts()

        XCTAssertEqual(viewModel.prompts.map(\.name), ["alpha", "Beta", "zeta"])
        XCTAssertEqual(viewModel.selectedPromptID, alpha.id)
    }

    func testRunTransformationSuccessTogglesRunningAndAppendsResult() async {
        let promptStore = AIPromptStore(defaults: defaults)
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let session = makeRecordingSession(transcriptText: "Transcript")

        let service = makeService(
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
        XCTAssertTrue(viewModel.isRunningTransformation)

        await task.value

        XCTAssertFalse(viewModel.isRunningTransformation)
        XCTAssertNil(viewModel.transformationErrorMessage)
        XCTAssertEqual(session.aiTransformations.count, 1)
        XCTAssertEqual(session.aiTransformations.first?.resultText, "Result text")
        XCTAssertEqual(session.aiTransformations.first?.promptName, "Summary")
        XCTAssertEqual(viewModel.selectedTransformationID, session.aiTransformations.first?.id)
        XCTAssertEqual(promptStore.loadLastUsedPromptID(), prompt.id)
    }

    func testRunTransformationErrorSurfacesMessageAndResetsRunning() async {
        let promptStore = AIPromptStore(defaults: defaults)
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let session = makeRecordingSession(transcriptText: "Transcript")

        let service = makeService(
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

        XCTAssertFalse(viewModel.isRunningTransformation)
        XCTAssertNotNil(viewModel.transformationErrorMessage)
        XCTAssertEqual(session.aiTransformations.count, 0)
    }

    func testDerivedSessionProperties() {
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

        let viewModel = TranscriptDetailViewModel(session: session, aiProviderService: makeService())

        XCTAssertEqual(viewModel.displayedTranscript?.fullText, "Retranscript")
        XCTAssertEqual(viewModel.finalTranscriptText, "Retranscript")
        XCTAssertEqual(viewModel.originalTranscriptText, "Original")
        XCTAssertEqual(viewModel.applicationName, "Zoom")
        XCTAssertEqual(viewModel.availableTransformations.map(\.promptName), ["Old", "New"])
        XCTAssertFalse(viewModel.canReprocess)
        XCTAssertTrue(viewModel.isReprocessing)
        XCTAssertTrue(viewModel.isReprocessed)
    }

    private func makeService(
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
                  "annotations": []
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
