import Foundation
import Combine
import OpenAI
import SwiftData
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
        service.isEnabled = true
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
    func testCanRunTransformationRequiresAIEnabled() async {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let promptStore = AIPromptStore(defaults: defaults)
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let session = makeRecordingSession(transcriptText: "Transcript")
        var responseCreatorCalls = 0

        let service = makeService(
            defaults: defaults,
            responseCreator: { _, _ in
                responseCreatorCalls += 1
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

        service.isEnabled = false
        #expect(viewModel.canRunTransformation == false)

        await viewModel.runTransformation()
        #expect(responseCreatorCalls == 0)
        #expect(session.aiTransformations.isEmpty)
        #expect(
            viewModel.transformationErrorMessage
                == AIProviderService.AITransformationError.disabled.localizedDescription
        )

        service.isEnabled = true
        #expect(viewModel.canRunTransformation)
    }

    @Test
    @MainActor
    func testRunsGoThroughTheSharedRunnerSoASecondWindowIsRefused() async {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let promptStore = AIPromptStore(defaults: defaults)
        let prompt = promptStore.addPrompt(name: "Summary", content: "Summarize")
        let session = makeRecordingSession(transcriptText: "Transcript")
        let (gate, release) = AsyncStream<Void>.makeStream()
        var responseCreatorCalls = 0

        let service = makeService(
            defaults: defaults,
            responseCreator: { _, _ in
                responseCreatorCalls += 1
                for await _ in gate { break }
                return try Self.makeResponse(text: "Result text")
            }
        )
        service.isEnabled = true
        service.selectedModelID = "gpt-5.2"

        let runner = AITransformationRunner(
            aiProviderService: service,
            promptStore: promptStore,
            sessionJobs: SessionJobs()
        )
        let firstWindow = TranscriptDetailViewModel(
            session: session,
            aiProviderService: service,
            promptStore: promptStore,
            aiTransformationRunner: runner
        )
        let secondWindow = TranscriptDetailViewModel(
            session: session,
            aiProviderService: service,
            promptStore: promptStore,
            aiTransformationRunner: runner
        )
        for viewModel in [firstWindow, secondWindow] {
            viewModel.prompts = [prompt]
            viewModel.selectedPromptID = prompt.id
        }

        let first = Task {
            await firstWindow.runTransformation()
        }
        for _ in 0..<1_000 where responseCreatorCalls == 0 {
            await Task.yield()
        }

        #expect(firstWindow.isRunningTransformation)
        #expect(secondWindow.isRunningTransformation)
        #expect(secondWindow.canRunTransformation == false)

        await secondWindow.runTransformation()
        #expect(responseCreatorCalls == 1)

        release.yield()
        release.finish()
        await first.value

        #expect(responseCreatorCalls == 1)
        #expect(session.aiTransformations.count == 1)
        #expect(session.aiTransformations.first?.resultText == "Result text")
        #expect(firstWindow.selectedTransformationID == session.aiTransformations.first?.id)
        #expect(firstWindow.transformationErrorMessage == nil)
        #expect(secondWindow.transformationErrorMessage == nil)
        #expect(firstWindow.isRunningTransformation == false)
        #expect(secondWindow.isRunningTransformation == false)
        #expect(promptStore.loadLastUsedPromptID() == prompt.id)
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

    @Test
    @MainActor
    func testSourcesTextForMicOnlyRecording() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let viewModel = TranscriptDetailViewModel(
            session: makeRecordingSession(capturedAppName: nil),
            aiProviderService: makeService(defaults: defaults)
        )

        #expect(viewModel.sourcesText == "Mic")
    }

    @Test
    @MainActor
    func testSourcesTextForCombinedCapture() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let viewModel = TranscriptDetailViewModel(
            session: makeRecordingSession(capturedAppName: "Chromium"),
            aiProviderService: makeService(defaults: defaults)
        )

        #expect(viewModel.sourcesText == "Mic + Chromium")
    }

    @Test
    @MainActor
    func testSourcesTextForImportedSession() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let imported = ImportedSession(
            duration: 30,
            title: "Imported",
            originalFileName: "meeting.m4a",
            originalFormat: "m4a"
        )
        let viewModel = TranscriptDetailViewModel(
            session: imported,
            aiProviderService: makeService(defaults: defaults)
        )

        #expect(viewModel.sourcesText == "Imported")
    }

    @Test
    @MainActor
    func testWordCountReflectsDisplayedTranscript() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let viewModel = TranscriptDetailViewModel(
            session: makeRecordingSession(transcriptText: "one two  three\nfour five"),
            aiProviderService: makeService(defaults: defaults)
        )

        #expect(viewModel.wordCount == 5)
    }

    @Test
    @MainActor
    func testWordCountIsZeroWithoutTranscript() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let viewModel = TranscriptDetailViewModel(
            session: makeRecordingSession(transcriptText: nil),
            aiProviderService: makeService(defaults: defaults)
        )

        #expect(viewModel.wordCount == 0)
    }

    @Test
    @MainActor
    func testDurationTextFormatsSessionDuration() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let viewModel = TranscriptDetailViewModel(
            session: makeRecordingSession(),
            aiProviderService: makeService(defaults: defaults)
        )

        // The header shows the display form — `0:10`, not the export's zero-padded `00:10`.
        #expect(viewModel.durationText == "0:10")
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

    static func makeResponse(text: String) throws -> ResponseObject {
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


/// What the transcript view shows and does, driven through the detail view model the way the view
/// drives it.
@MainActor
struct TranscriptDetailViewModelTranscriptTests {
    private func makeViewModel(
        session: any TranscribableSession,
        store: SpeakerEmbeddingStore? = nil,
        saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() },
        writeSpeakerData: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) -> TranscriptDetailViewModel {
        let suiteName = "TranscriptDetailViewModelTranscriptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return TranscriptDetailViewModel(
            session: session,
            aiProviderService: AIProviderService(keychainStore: MockKeychainStore(), store: AIProviderStore(defaults: defaults)),
            promptStore: AIPromptStore(defaults: defaults),
            store: store,
            transcript: session.displayedTranscript,
            saveContext: saveContext,
            writeSpeakerData: writeSpeakerData
        )
    }

    private func conversation() -> Transcript {
        Transcript(
            fullText: "hello there the migration plan later on the migration again",
            segments: [
                TranscriptSegment(speakerId: "S1", text: "hello there", startTime: 0, endTime: 2),
                TranscriptSegment(speakerId: "S1", text: "the migration plan", startTime: 2, endTime: 4),
                TranscriptSegment(speakerId: "S2", text: "later on", startTime: 6, endTime: 8),
                TranscriptSegment(speakerId: "S1", text: "the migration again", startTime: 8, endTime: 10)
            ],
            speakers: [
                TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#112233"),
                TranscriptSpeaker(id: "S2", label: "Speaker 2", colorHex: "#445566")
            ]
        )
    }

    private func conversationSession() -> RecordingSession {
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/conversation/mic.wav", title: "Conversation")
        session.transcript = conversation()
        return session
    }

    // MARK: - Blocks

    @Test
    func testBlocksAreTheGroupersBlocksForTheDisplayedTranscript() throws {
        let session = conversationSession()
        session.retranscript = Transcript(
            fullText: "second pass",
            segments: [TranscriptSegment(speakerId: "S9", text: "second pass", startTime: 0, endTime: 1)],
            speakers: [TranscriptSpeaker(id: "S9", label: "Speaker 9", colorHex: "#778899")]
        )
        let viewModel = makeViewModel(session: session)

        let expected = TranscriptGrouper.makeBlocks(from: try #require(session.retranscript))
        #expect(viewModel.blocks.map(\.id) == expected.map(\.id))
        #expect(viewModel.blocks.map(\.text) == ["second pass"])
    }

    @Test
    func testRefreshFollowsTheDisplayedTranscriptAndItsMatches() {
        let session = conversationSession()
        let viewModel = makeViewModel(session: session)
        viewModel.searchState.query = "migration"
        viewModel.updateSearch()
        #expect(viewModel.searchState.matches.count == 2)

        session.retranscript = Transcript(
            fullText: "no match here",
            segments: [TranscriptSegment(speakerId: "S1", text: "no match here", startTime: 0, endTime: 1)],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#112233")]
        )
        viewModel.refreshTranscript()

        #expect(viewModel.shownTranscript == session.retranscript)
        #expect(viewModel.blocks.map(\.text) == ["no match here"])
        #expect(viewModel.searchState.matches.isEmpty)
    }

    @Test
    func testASessionWithoutATranscriptHasNoBlocks() {
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/empty/mic.wav", title: "Empty")
        let viewModel = makeViewModel(session: session)

        #expect(viewModel.shownTranscript == nil)
        #expect(viewModel.blocks.isEmpty)
    }

    // MARK: - Active block

    @Test
    func testActiveBlockInsideBetweenAndAfterBlocks() {
        let viewModel = makeViewModel(session: conversationSession())
        let blocks = viewModel.blocks
        #expect(blocks.count == 3)

        #expect(viewModel.activeBlock(at: 0)?.id == blocks[0].id)
        #expect(viewModel.activeBlock(at: 3.5)?.id == blocks[0].id)
        #expect(viewModel.activeBlock(at: 7)?.id == blocks[1].id)
        // Between the first block's end and the second block's start.
        #expect(viewModel.activeBlock(at: 5) == nil)
        #expect(viewModel.activeBlock(at: 10) == nil)
        #expect(viewModel.activeBlock(at: 60) == nil)
    }

    // MARK: - Search seed

    @Test
    func testASeedAppliesTheQueryAndSelectsTheMatchedBlock() {
        let viewModel = makeViewModel(session: conversationSession())
        let lastBlock = viewModel.blocks[2]

        let applied = viewModel.applySearchSeed(TranscriptSearchSeed(query: "migration", blockID: lastBlock.id))

        #expect(applied)
        #expect(viewModel.searchState.query == "migration")
        #expect(viewModel.searchState.matches.count == 2)
        #expect(viewModel.searchState.currentMatch?.blockID == lastBlock.id)
        #expect(viewModel.isSearchVisible)
    }

    @Test
    func testTheSameSeedWithANewTokenReapplies() {
        let viewModel = makeViewModel(session: conversationSession())
        let lastBlock = viewModel.blocks[2]
        let first = TranscriptSearchSeed(query: "migration", blockID: lastBlock.id)
        viewModel.applySearchSeed(first)
        viewModel.searchState.next()
        #expect(viewModel.searchState.currentMatch?.blockID == viewModel.blocks[0].id)

        let again = TranscriptSearchSeed(query: first.query, blockID: first.blockID)
        #expect(again != first)
        viewModel.applySearchSeed(again)

        #expect(viewModel.searchState.currentMatch?.blockID == lastBlock.id)
    }

    @Test
    func testATitleOnlySeedSelectsNothing() {
        let viewModel = makeViewModel(session: conversationSession())

        viewModel.applySearchSeed(TranscriptSearchSeed(query: "Conversation", blockID: nil))

        #expect(viewModel.searchState.currentMatch == nil)
        #expect(viewModel.searchState.matches.isEmpty)
    }

    @Test
    func testNoSeedOrAnEmptyQueryLeavesFindAlone() {
        let viewModel = makeViewModel(session: conversationSession())

        #expect(viewModel.applySearchSeed(nil) == false)
        #expect(viewModel.applySearchSeed(TranscriptSearchSeed(query: "", blockID: viewModel.blocks[0].id)) == false)
        #expect(viewModel.searchState.query.isEmpty)
        #expect(viewModel.isSearchVisible == false)
    }

    // MARK: - Find

    @Test
    func testFindQueryUpdatesRangesAndStepsWrap() {
        let viewModel = makeViewModel(session: conversationSession())
        let blocks = viewModel.blocks

        viewModel.presentSearch()
        viewModel.searchState.query = "MIGRATION"
        viewModel.updateSearch()

        #expect(viewModel.isSearchVisible)
        #expect(viewModel.searchState.ranges(in: blocks[0]).count == 1)
        #expect(viewModel.searchState.ranges(in: blocks[1]).isEmpty)
        #expect(viewModel.searchState.currentMatch?.blockID == blocks[0].id)
        viewModel.searchState.next()
        #expect(viewModel.searchState.currentMatch?.blockID == blocks[2].id)
        viewModel.searchState.next()
        #expect(viewModel.searchState.currentMatch?.blockID == blocks[0].id)
        viewModel.searchState.previous()
        #expect(viewModel.searchState.currentMatch?.blockID == blocks[2].id)
    }

    /// A seeded search is cleared by the same call as one the user typed.
    @Test
    func testClearingRemovesHighlights() {
        let viewModel = makeViewModel(session: conversationSession())
        viewModel.applySearchSeed(TranscriptSearchSeed(query: "migration", blockID: viewModel.blocks[2].id))

        viewModel.clearSearch()

        #expect(viewModel.searchState.query.isEmpty)
        #expect(viewModel.searchState.matches.isEmpty)
        #expect(viewModel.blocks.allSatisfy { viewModel.searchState.ranges(in: $0).isEmpty })
        #expect(viewModel.searchState.currentMatch == nil)
    }

    // MARK: - Raw Markdown

    @Test
    func testRawMarkdownIsTheExportRendering() throws {
        let session = conversationSession()
        let viewModel = makeViewModel(session: session)

        let exported = MarkdownRenderer().renderMarkdown(session: session, transcript: try #require(session.displayedTranscript))
        #expect(viewModel.rawMarkdown == exported)
    }

    // MARK: - Speaker edits through the view model

    private func makeStore() throws -> SpeakerEmbeddingStore {
        let container = try ModelContainer(
            for: SpeakerProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return SpeakerEmbeddingStore(modelContainer: container)
    }

    private func names(in store: SpeakerEmbeddingStore) async throws -> Set<String> {
        Set(try await store.fetchAllSnapshots().map(\.name))
    }

    private func teachableConversation() -> Transcript {
        var transcript = conversation()
        transcript.voiceprintSpace = VoiceprintSpace.current
        transcript.speakerVoiceprints = ["S1": [[1, 0]], "S2": [[0, 1]]]
        return transcript
    }

    @Test
    func testRenameWritesTheDisplayedPassAndTeachesItsSource() async throws {
        let store = try makeStore()
        let session = conversationSession()
        session.retranscript = teachableConversation()
        let firstPassBefore = session.transcriptData
        let viewModel = makeViewModel(session: session, store: store)

        await viewModel.renameSpeaker(id: "S1", to: "  Ana \n")?.value

        #expect(viewModel.shownTranscript?.speakers.map(\.label) == ["Ana", "Speaker 2"])
        #expect(session.retranscript == viewModel.shownTranscript)
        #expect(session.transcriptData == firstPassBefore)
        #expect(viewModel.blocks.first?.speaker.label == "Ana")
        #expect(try await names(in: store) == ["Ana"])
        let anaID = try #require(try await store.profileID(forName: "Ana"))
        #expect(try await store.findProfileSnapshot(byID: anaID)?.embedding == [1, 0])

        // The memory now holds the retranscript's voiceprint source: a second rename moves it.
        await viewModel.renameSpeaker(id: "S1", to: "Bea")?.value
        #expect(try await names(in: store) == ["Bea"])
    }

    @Test
    func testRenameToTheSameLabelChangesNothing() throws {
        let session = conversationSession()
        let before = session.transcriptData
        let viewModel = makeViewModel(session: session, store: try makeStore())

        #expect(viewModel.renameSpeaker(id: "S1", to: "Speaker 1") == nil)
        #expect(viewModel.renameSpeaker(id: "S1", to: "   ") == nil)
        #expect(session.transcriptData == before)
    }

    @Test
    func testRenameChangingOnlyCaseWritesButTeachesNothing() async throws {
        let store = try makeStore()
        let session = conversationSession()
        session.transcript = teachableConversation()
        let viewModel = makeViewModel(session: session, store: store)

        #expect(viewModel.renameSpeaker(id: "S1", to: "speaker 1") == nil)

        #expect(session.transcript?.speakers.first?.label == "speaker 1")
        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    @Test
    func testMergeIntoANamedSpeakerWritesAndTeachesItsProfile() async throws {
        let store = try makeStore()
        let session = conversationSession()
        session.transcript = try #require(TranscriptSpeakerEditing.rename("S1", to: "Alice", in: teachableConversation()))
        let viewModel = makeViewModel(session: session, store: store)
        await viewModel.renameSpeaker(id: "S1", to: "Alicia")?.value
        #expect(try await store.fetchAllSnapshots().map(\.sampleCount) == [1])

        await viewModel.mergeSpeaker("S2", into: "S1")?.value

        #expect(viewModel.shownTranscript?.speakers.map(\.id) == ["S1"])
        #expect(session.transcript == viewModel.shownTranscript)
        #expect(viewModel.blocks.count == 1)
        #expect(try await names(in: store) == ["Alicia"])
        #expect(try await store.fetchAllSnapshots().map(\.sampleCount) == [2])
    }

    @Test
    func testResetWritesTheLabelAndForgetsWhatTheSpeakerTaught() async throws {
        let store = try makeStore()
        let session = conversationSession()
        session.transcript = teachableConversation()
        let viewModel = makeViewModel(session: session, store: store)
        await viewModel.renameSpeaker(id: "S2", to: "Bob")?.value
        #expect(try await names(in: store) == ["Bob"])

        await viewModel.resetSpeaker("S2")?.value

        #expect(session.transcript?.speakers.map(\.label) == ["Speaker 1", "Speaker 2"])
        #expect(session.transcript == viewModel.shownTranscript)
        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    @Test
    func testAssigningABlockWritesTheDisplayedPassAndLeavesMemoryAlone() async throws {
        let store = try makeStore()
        let session = conversationSession()
        session.transcript = teachableConversation()
        let viewModel = makeViewModel(session: session, store: store)
        let laterBlock = viewModel.blocks[1]

        viewModel.assign(laterBlock, to: "S1")

        #expect(viewModel.blocks.count == 1)
        #expect(session.transcript == viewModel.shownTranscript)
        #expect(try await store.fetchAllSnapshots().isEmpty)

        viewModel.assign(viewModel.blocks[0], to: "missing")
        #expect(session.transcript == viewModel.shownTranscript)
        #expect(viewModel.blocks.count == 1)
    }

    @Test
    func testEditsWithoutAStoreStillWriteTheTranscript() {
        let session = conversationSession()
        let viewModel = makeViewModel(session: session)

        #expect(viewModel.renameSpeaker(id: "S1", to: "Ana") == nil)

        #expect(session.transcript?.speakers.first?.label == "Ana")
    }

    // MARK: - Moved from the study view's tests

    // MARK: - Session identity

    /// Search result A, then search result B, then a speaker rename: only B may change.
    @Test
    func testRenamingASpeakerWritesOnlyTheViewsSession() throws {
        let sessionA = RecordingSession(duration: 10, micAudioURL: "/tmp/a/mic.wav", title: "A")
        let sessionB = RecordingSession(duration: 10, micAudioURL: "/tmp/b/mic.wav", title: "B")
        sessionA.transcript = transcript(text: "session a words", speakerLabel: "Speaker 1")
        sessionB.transcript = transcript(text: "session b words", speakerLabel: "Speaker 1")
        let sessionABefore = sessionA.transcriptData

        let shownForB = try #require(sessionB.retranscript ?? sessionB.transcript)
        let renamed = try #require(TranscriptDetailViewModel.renameSpeaker(id: "S1", to: "Ana", in: shownForB, of: sessionB))

        #expect(renamed.speakers.map(\.label) == ["Ana"])
        #expect(sessionB.transcript?.speakers.map(\.label) == ["Ana"])
        #expect(sessionB.transcript?.fullText == "session b words")
        #expect(sessionA.transcriptData == sessionABefore)
    }

    @Test
    func testRenamingWritesTheRetranscriptWhenOneIsDisplayed() throws {
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/c/mic.wav", title: "C")
        session.transcript = transcript(text: "first pass", speakerLabel: "Speaker 1")
        session.retranscript = transcript(text: "second pass", speakerLabel: "Speaker 1")
        let firstPassBefore = session.transcriptData

        let shown = try #require(session.retranscript)
        _ = TranscriptDetailViewModel.renameSpeaker(id: "S1", to: "Ana", in: shown, of: session)

        #expect(session.retranscript?.speakers.map(\.label) == ["Ana"])
        #expect(session.transcriptData == firstPassBefore)
    }

    @Test
    func testRenamingKeepsVoiceprintsAndProfileLinks() throws {
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/e/mic.wav", title: "E")
        let profileID = UUID()
        var original = transcript(text: "words", speakerLabel: "Speaker 1")
        original.speakerEmbeddings = ["S1": [0.5]]
        original.speakerProfileIDs = ["S1": profileID]
        original.voiceprintSpace = VoiceprintSpace.current
        session.transcript = original

        let renamed = try #require(TranscriptDetailViewModel.renameSpeaker(id: "S1", to: "Ana", in: original, of: session))

        #expect(renamed.speakerEmbeddings == ["S1": [0.5]])
        #expect(renamed.speakerProfileIDs == ["S1": profileID])
        #expect(renamed.voiceprintSpace == VoiceprintSpace.current)
    }

    @Test
    func testAssigningABlockWritesTheDisplayedPassAndKeepsVoiceprints() throws {
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/k/mic.wav", title: "K")
        var shown = Transcript(
            fullText: "one two",
            segments: [
                TranscriptSegment(speakerId: "S1", text: "one", startTime: 0, endTime: 1),
                TranscriptSegment(speakerId: "S1", text: "two", startTime: 1, endTime: 2)
            ],
            speakers: [TranscriptSpeaker(id: "S1", label: "Alice", colorHex: "#112233")],
            voiceprintSpace: VoiceprintSpace.current
        )
        shown.speakerVoiceprints = ["S1": [[1, 0]]]
        session.transcript = shown

        let edited = try #require(TranscriptDetailViewModel.assign(segmentIDs: [shown.segments[1].id], to: nil, in: shown, of: session))

        #expect(edited.speakers.map(\.label) == ["Alice", "Speaker 1"])
        #expect(edited.speakerVoiceprints == shown.speakerVoiceprints)
        #expect(session.transcript == edited)
        #expect(TranscriptDetailViewModel.assign(segmentIDs: [], to: "missing", in: shown, of: session) == nil)
    }

    @Test
    func testRenamingAnUnknownSpeakerWritesNothing() {
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/d/mic.wav", title: "D")
        session.transcript = transcript(text: "words", speakerLabel: "Speaker 1")
        let before = session.transcriptData

        let result = TranscriptDetailViewModel.renameSpeaker(id: "missing", to: "Ana", in: session.transcript!, of: session)

        #expect(result == nil)
        #expect(session.transcriptData == before)
    }

    // MARK: - Rename into speaker memory

    private func liveTranscript(voiceprint: [Float], voiceprintSpace: String? = VoiceprintSpace.current) -> Transcript {
        var transcript = transcript(text: "words", speakerLabel: "Speaker 1")
        transcript.speakerEmbeddings = ["S1": voiceprint]
        transcript.voiceprintSpace = voiceprintSpace
        return transcript
    }

    private let source = VoiceprintSource(sessionID: UUID(), pass: .transcript, speakerID: "S1")

    /// Spec scenario "User names an unknown speaker".
    @Test
    func testRenamingAnUnknownSpeakerCreatesAProfile() async throws {
        let store = try makeStore()

        try await TranscriptDetailViewModel.updateSpeakerMemory(
            forRenaming: "S1", to: "Bob", in: liveTranscript(voiceprint: [0.5, 0.5]), source: source, store: store
        )

        #expect(try await names(in: store) == ["Bob"])
        let bobID = try #require(try await store.profileID(forName: "Bob"))
        let bob = try #require(try await store.findProfileSnapshot(byID: bobID))
        #expect(bob.embedding == [0.5, 0.5])
        #expect(bob.sampleCount == 1)
    }

    /// Spec scenario "Rename to an existing profile's name".
    @Test
    func testRenamingToAnExistingNameFoldsIntoThatProfile() async throws {
        let store = try makeStore()
        let aliceID = try await store.teach(name: "Alice", voiceprint: [1, 0])

        try await TranscriptDetailViewModel.updateSpeakerMemory(
            forRenaming: "S1", to: "alice", in: liveTranscript(voiceprint: [0, 1]), source: source, store: store
        )

        #expect(try await names(in: store) == ["Alice"])
        let alice = try #require(try await store.findProfileSnapshot(byID: aliceID))
        #expect(alice.embedding == [0.5, 0.5])
        #expect(alice.sampleCount == 2)
    }

    /// Spec scenario "Rename a speaker that was matched to another profile".
    @Test
    func testRenamingAMatchedSpeakerKeepsTheMatchedProfileName() async throws {
        let store = try makeStore()
        let aliceID = try await store.teach(name: "Alice", voiceprint: [0.1])

        try await TranscriptDetailViewModel.updateSpeakerMemory(
            forRenaming: "S1", to: "Carol", in: liveTranscript(voiceprint: [0.1]), source: source, store: store
        )

        #expect(try await store.findProfileSnapshot(byID: aliceID)?.name == "Alice")
        #expect(try await store.findProfileSnapshot(byID: aliceID)?.embedding == [0.1])
        #expect(try await names(in: store) == ["Alice", "Carol"])
    }

    /// Spec scenario "Rename in a transcript from before the voiceprint space".
    @Test
    func testRenamingInATranscriptWithoutVoiceprintSpaceWritesNothing() async throws {
        let store = try makeStore()
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/h/mic.wav", title: "H")
        let original = liveTranscript(voiceprint: [0.5], voiceprintSpace: nil)
        session.transcript = original

        let renamed = try #require(TranscriptDetailViewModel.renameSpeaker(id: "S1", to: "Bob", in: original, of: session))
        try await TranscriptDetailViewModel.updateSpeakerMemory(forRenaming: "S1", to: "Bob", in: renamed, source: source, store: store)

        #expect(session.transcript?.speakers.map(\.label) == ["Bob"])
        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    @Test
    func testRenamingWithARetranscriptTeachesFromTheRetranscriptPass() throws {
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/j/mic.wav", title: "J")
        session.transcript = transcript(text: "first pass", speakerLabel: "Speaker 1")
        #expect(TranscriptDetailViewModel.voiceprintSource(for: "S1", of: session).pass == .transcript)

        session.retranscript = transcript(text: "second pass", speakerLabel: "Speaker 1")

        let source = TranscriptDetailViewModel.voiceprintSource(for: "S1", of: session)
        #expect(source == VoiceprintSource(sessionID: session.id, pass: .retranscript, speakerID: "S1"))
    }

    /// Spec scenario "Wrong name corrected by renaming again".
    @Test
    func testRenamingAgainMovesTheVoiceprints() async throws {
        let store = try makeStore()
        let shown = liveTranscript(voiceprint: [0.5, 0.5])

        try await TranscriptDetailViewModel.updateSpeakerMemory(forRenaming: "S1", to: "Bob", in: shown, source: source, store: store)
        try await TranscriptDetailViewModel.updateSpeakerMemory(forRenaming: "S1", to: "Carol", in: shown, source: source, store: store)

        #expect(try await names(in: store) == ["Carol"])
    }

    private func twoSpeakerTranscript(targetLabel: String) -> Transcript {
        var transcript = Transcript(
            fullText: "one two",
            segments: [
                TranscriptSegment(speakerId: "S1", text: "one", startTime: 0, endTime: 1),
                TranscriptSegment(speakerId: "S3", text: "two", startTime: 1, endTime: 2)
            ],
            speakers: [
                TranscriptSpeaker(id: "S1", label: targetLabel, colorHex: "#112233"),
                TranscriptSpeaker(id: "S3", label: "Speaker 3", colorHex: "#445566")
            ],
            voiceprintSpace: VoiceprintSpace.current
        )
        transcript.speakerVoiceprints = ["S1": [[1, 0]], "S3": [[0.9, 0.1]]]
        return transcript
    }

    /// Spec scenario "Merge into a named speaker".
    @Test
    func testMergingIntoANamedSpeakerTeachesItsProfile() async throws {
        let store = try makeStore()
        for _ in 0..<4 {
            try await store.teach(name: "Alice", voiceprint: [1, 0])
        }
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/l/mic.wav", title: "L")
        let original = twoSpeakerTranscript(targetLabel: "Alice")
        session.transcript = original

        let merged = try #require(TranscriptDetailViewModel.mergeSpeaker("S3", into: "S1", in: original, of: session))
        try await TranscriptDetailViewModel.updateSpeakerMemory(
            forMerging: "S3", into: "S1", in: original,
            source: TranscriptDetailViewModel.voiceprintSource(for: "S3", of: session),
            targetSource: TranscriptDetailViewModel.voiceprintSource(for: "S1", of: session),
            store: store
        )

        #expect(session.transcript == merged)
        #expect(try await store.fetchAllSnapshots().map(\.sampleCount) == [5])
    }

    /// Spec scenario "Merge into an unnamed speaker".
    @Test
    func testMergingIntoAnUnnamedSpeakerTeachesNothing() async throws {
        let store = try makeStore()
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/m/mic.wav", title: "M")
        let original = twoSpeakerTranscript(targetLabel: "Speaker 1")

        try await TranscriptDetailViewModel.updateSpeakerMemory(
            forMerging: "S3", into: "S1", in: original,
            source: TranscriptDetailViewModel.voiceprintSource(for: "S3", of: session),
            targetSource: TranscriptDetailViewModel.voiceprintSource(for: "S1", of: session),
            store: store
        )

        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    /// Spec scenario "Wrong name undone".
    @Test
    func testResettingWritesTheLabelAndForgetsWhatTheSpeakerTaught() async throws {
        let store = try makeStore()
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/n/mic.wav", title: "N")
        let named = try #require(TranscriptSpeakerEditing.rename("S3", to: "Bob", in: twoSpeakerTranscript(targetLabel: "Speaker 1")))
        session.transcript = named
        let source = TranscriptDetailViewModel.voiceprintSource(for: "S3", of: session)
        try await TranscriptDetailViewModel.updateSpeakerMemory(forRenaming: "S3", to: "Bob", in: named, source: source, store: store)
        #expect(try await names(in: store) == ["Bob"])

        let reset = try #require(TranscriptDetailViewModel.resetSpeaker("S3", in: named, of: session))
        try await store.forget(source: source)

        #expect(reset.speakers.map(\.label) == ["Speaker 1", "Speaker 2"])
        #expect(session.transcript == reset)
        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    @Test
    func testRenamingWithoutAVoiceprintWritesNothing() async throws {
        let store = try makeStore()
        var transcript = transcript(text: "words", speakerLabel: "Speaker 1")
        transcript.voiceprintSpace = VoiceprintSpace.current

        try await TranscriptDetailViewModel.updateSpeakerMemory(forRenaming: "S1", to: "Bob", in: transcript, source: source, store: store)

        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    /// Spec scenario "Rename after trim": the space survives the trim and both renames, and the
    /// second rename still teaches speaker memory.
    @Test
    func testTrimThenRenameTwiceKeepsTeachingSpeakerMemory() async throws {
        let store = try makeStore()
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/i/mic.wav", title: "I")
        let original = Transcript(
            fullText: "one two three",
            segments: [
                TranscriptSegment(speakerId: "S1", text: "one", startTime: 0, endTime: 1),
                TranscriptSegment(speakerId: "S2", text: "two", startTime: 1, endTime: 2),
                TranscriptSegment(speakerId: "S1", text: "three", startTime: 8, endTime: 9)
            ],
            speakers: [
                TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#112233"),
                TranscriptSpeaker(id: "S2", label: "Speaker 2", colorHex: "#445566")
            ],
            speakerEmbeddings: ["S1": [1, 0], "S2": [0, 1]],
            voiceprintSpace: VoiceprintSpace.current
        )

        let trimmed = AudioTrimService.trimmedTranscript(original, end: 5)
        #expect(trimmed.voiceprintSpace == VoiceprintSpace.current)
        #expect(trimmed.segments.map(\.text) == ["one", "two"])
        session.transcript = trimmed

        let first = try #require(TranscriptDetailViewModel.renameSpeaker(id: "S1", to: "Ana", in: trimmed, of: session))
        #expect(first.voiceprintSpace == VoiceprintSpace.current)
        try await TranscriptDetailViewModel.updateSpeakerMemory(
            forRenaming: "S1", to: "Ana", in: first,
            source: TranscriptDetailViewModel.voiceprintSource(for: "S1", of: session), store: store
        )

        let second = try #require(TranscriptDetailViewModel.renameSpeaker(id: "S2", to: "Ben", in: first, of: session))
        #expect(second.voiceprintSpace == VoiceprintSpace.current)
        #expect(session.transcript?.voiceprintSpace == VoiceprintSpace.current)
        try await TranscriptDetailViewModel.updateSpeakerMemory(
            forRenaming: "S2", to: "Ben", in: second,
            source: TranscriptDetailViewModel.voiceprintSource(for: "S2", of: session), store: store
        )

        #expect(try await names(in: store) == ["Ana", "Ben"])
        let benID = try #require(try await store.profileID(forName: "Ben"))
        #expect(try await store.findProfileSnapshot(byID: benID)?.embedding == [0, 1])
    }

    private func transcript(text: String, speakerLabel: String) -> Transcript {
        Transcript(
            fullText: text,
            segments: [TranscriptSegment(speakerId: "S1", text: text, startTime: 0, endTime: 1)],
            speakers: [TranscriptSpeaker(id: "S1", label: speakerLabel, colorHex: "#112233")]
        )
    }
}

// MARK: - Title commits

extension TranscriptDetailViewModelTests {
    @MainActor
    private func makeTitleFixture(saveFails: Bool) throws -> (
        viewModel: TranscriptDetailViewModel, session: RecordingSession, context: ModelContext,
        container: ModelContainer, markdownURL: URL, directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let session = makeRecordingSession()
        session.title = "Old Title"
        session.micAudioURL = directory.appendingPathComponent("mic.wav").path
        context.insert(session)
        try context.save()
        rewriteTranscriptMarkdown(for: session)

        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }
        let viewModel = TranscriptDetailViewModel(
            session: session,
            aiProviderService: makeService(defaults: defaults),
            saveContext: { context in
                if saveFails { throw TestError.expectedFailure }
                try context.save()
            }
        )
        return (viewModel, session, context, container, directory.appendingPathComponent("transcript.md"), directory)
    }

    @Test
    @MainActor
    func testFailedTitleSaveKeepsTitleAndTranscriptMarkdownAndReportsFailure() throws {
        let fixture = try makeTitleFixture(saveFails: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let markdownBefore = try String(contentsOf: fixture.markdownURL, encoding: .utf8)

        let result = fixture.viewModel.commitTitle("New Title", context: fixture.context)

        #expect(result == .saveFailed("Expected failure"))
        #expect(fixture.session.title == "Old Title")
        let stored = try ModelContext(fixture.container).fetch(FetchDescriptor<RecordingSession>())
        #expect(stored.map(\.title) == ["Old Title"])
        #expect(try String(contentsOf: fixture.markdownURL, encoding: .utf8) == markdownBefore)
    }

    @Test
    @MainActor
    func testSavedTitleUpdatesStoreAndTranscriptMarkdown() throws {
        let fixture = try makeTitleFixture(saveFails: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = fixture.viewModel.commitTitle("New Title", context: fixture.context)

        #expect(result == .saved)
        #expect(fixture.session.title == "New Title")
        let stored = try ModelContext(fixture.container).fetch(FetchDescriptor<RecordingSession>())
        #expect(stored.map(\.title) == ["New Title"])
        let markdown = try String(contentsOf: fixture.markdownURL, encoding: .utf8)
        #expect(markdown.hasPrefix(MarkdownRenderer().header(for: fixture.session)))
        #expect(markdown.contains("New Title"))
        #expect(!markdown.contains("Old Title"))
    }
}

// MARK: - Undo

extension UndoManager {
    /// An undo manager whose groups the test opens itself: there is no event loop to close them.
    static func forTests() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    /// Runs `body` as one undoable event.
    @discardableResult
    func asOneEvent<T>(_ body: () throws -> T) rethrows -> T {
        beginUndoGrouping()
        defer { endUndoGrouping() }
        return try body()
    }
}

extension TranscriptDetailViewModelTests {
    @Test
    @MainActor
    func testUndoAndRedoATitleCommitRestoreStoreAndTranscriptMarkdown() throws {
        let fixture = try makeTitleFixture(saveFails: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let undoManager = UndoManager.forTests()

        undoManager.asOneEvent { _ = fixture.viewModel.commitTitle("New Title", context: fixture.context, undoManager: undoManager) }
        #expect(undoManager.undoActionName == UndoActionName.renameSession)

        undoManager.undo()
        #expect(fixture.session.title == "Old Title")
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<RecordingSession>()).map(\.title) == ["Old Title"])
        let undoneMarkdown = try String(contentsOf: fixture.markdownURL, encoding: .utf8)
        #expect(undoneMarkdown.contains("Old Title"))
        #expect(!undoneMarkdown.contains("New Title"))
        #expect(undoManager.redoActionName == UndoActionName.renameSession)

        undoManager.redo()
        #expect(fixture.session.title == "New Title")
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<RecordingSession>()).map(\.title) == ["New Title"])
        #expect(try String(contentsOf: fixture.markdownURL, encoding: .utf8).contains("New Title"))
        #expect(undoManager.canUndo)
    }

    @Test
    @MainActor
    func testCommittingAnUnchangedOrUnsavedTitleRegistersNothing() throws {
        let saved = try makeTitleFixture(saveFails: false)
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let failing = try makeTitleFixture(saveFails: true)
        defer { try? FileManager.default.removeItem(at: failing.directory) }
        let undoManager = UndoManager.forTests()

        undoManager.asOneEvent { _ = saved.viewModel.commitTitle("Old Title", context: saved.context, undoManager: undoManager) }
        undoManager.asOneEvent { _ = failing.viewModel.commitTitle("New Title", context: failing.context, undoManager: undoManager) }

        #expect(undoManager.undoActionName.isEmpty)
    }
}

extension TranscriptDetailViewModelTranscriptTests {
    @Test
    func testUndoAndRedoARenameRestoreTranscriptAndSpeakerMemory() async throws {
        let store = try makeStore()
        let session = conversationSession()
        session.transcript = teachableConversation()
        let before = session.transcript
        let viewModel = makeViewModel(session: session, store: store)
        let undoManager = UndoManager.forTests()

        await undoManager.asOneEvent { viewModel.renameSpeaker(id: "S1", to: "Ana", undoManager: undoManager) }?.value
        #expect(undoManager.undoActionName == UndoActionName.renameSpeaker)
        #expect(try await names(in: store) == ["Ana"])

        undoManager.undo()
        await viewModel.speakerMemoryUpdate?.value
        #expect(session.transcript == before)
        #expect(viewModel.shownTranscript == before)
        #expect(try await store.fetchAllSnapshots().isEmpty)

        undoManager.redo()
        await viewModel.speakerMemoryUpdate?.value
        #expect(session.transcript?.speakers.map(\.label) == ["Ana", "Speaker 2"])
        #expect(viewModel.shownTranscript == session.transcript)
        #expect(try await names(in: store) == ["Ana"])
    }

    @Test
    func testUndoAndRedoAMergeRestoreTranscriptAndSpeakerMemory() async throws {
        let store = try makeStore()
        let session = conversationSession()
        session.transcript = try #require(TranscriptSpeakerEditing.rename("S1", to: "Alice", in: teachableConversation()))
        let viewModel = makeViewModel(session: session, store: store)
        await viewModel.renameSpeaker(id: "S1", to: "Alicia")?.value
        let before = session.transcript
        let undoManager = UndoManager.forTests()

        await undoManager.asOneEvent { viewModel.mergeSpeaker("S2", into: "S1", undoManager: undoManager) }?.value
        #expect(undoManager.undoActionName == UndoActionName.mergeSpeaker)
        #expect(try await store.fetchAllSnapshots().map(\.sampleCount) == [2])

        undoManager.undo()
        await viewModel.speakerMemoryUpdate?.value
        #expect(session.transcript == before)
        #expect(viewModel.blocks.count == 3)
        #expect(try await store.fetchAllSnapshots().map(\.sampleCount) == [1])
        #expect(try await names(in: store) == ["Alicia"])

        undoManager.redo()
        await viewModel.speakerMemoryUpdate?.value
        #expect(session.transcript?.speakers.map(\.id) == ["S1"])
        #expect(try await store.fetchAllSnapshots().map(\.sampleCount) == [2])
    }

    @Test
    func testUndoAndRedoAResetRestoreTranscriptAndSpeakerMemory() async throws {
        let store = try makeStore()
        let session = conversationSession()
        session.transcript = teachableConversation()
        let viewModel = makeViewModel(session: session, store: store)
        await viewModel.renameSpeaker(id: "S2", to: "Bob")?.value
        let before = session.transcript
        let undoManager = UndoManager.forTests()

        await undoManager.asOneEvent { viewModel.resetSpeaker("S2", undoManager: undoManager) }?.value
        #expect(undoManager.undoActionName == UndoActionName.resetSpeaker)
        #expect(try await store.fetchAllSnapshots().isEmpty)

        undoManager.undo()
        await viewModel.speakerMemoryUpdate?.value
        #expect(session.transcript == before)
        #expect(try await names(in: store) == ["Bob"])

        undoManager.redo()
        await viewModel.speakerMemoryUpdate?.value
        #expect(session.transcript?.speakers.map(\.label) == ["Speaker 1", "Speaker 2"])
        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    @Test
    func testUndoAndRedoAReassignRestoreTheTranscript() async throws {
        let store = try makeStore()
        let session = conversationSession()
        session.transcript = teachableConversation()
        let before = session.transcript
        let viewModel = makeViewModel(session: session, store: store)
        let undoManager = UndoManager.forTests()
        let laterBlock = viewModel.blocks[1]

        undoManager.asOneEvent { viewModel.assign(laterBlock, to: "S1", undoManager: undoManager) }
        #expect(undoManager.undoActionName == UndoActionName.reassignSpeaker)
        let after = session.transcript

        undoManager.undo()
        await viewModel.speakerMemoryUpdate?.value
        #expect(session.transcript == before)
        #expect(viewModel.blocks.count == 3)

        undoManager.redo()
        await viewModel.speakerMemoryUpdate?.value
        #expect(session.transcript == after)
        #expect(viewModel.blocks.count == 1)
        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    @Test
    func testUndoAfterTheTranscriptChangedElsewhereLeavesItAlone() {
        let session = conversationSession()
        let viewModel = makeViewModel(session: session)
        let undoManager = UndoManager.forTests()

        undoManager.asOneEvent { _ = viewModel.renameSpeaker(id: "S1", to: "Ana", undoManager: undoManager) }
        let retranscript = Transcript(
            fullText: "second pass",
            segments: [TranscriptSegment(speakerId: "S9", text: "second pass", startTime: 0, endTime: 1)],
            speakers: [TranscriptSpeaker(id: "S9", label: "Speaker 9", colorHex: "#778899")]
        )
        session.retranscript = retranscript

        undoManager.undo()

        #expect(session.retranscript == retranscript)
        #expect(session.transcript?.speakers.first?.label == "Ana")
    }

    @Test
    func testUndoRewritesTranscriptMarkdown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = conversationSession()
        session.micAudioURL = directory.appendingPathComponent("mic.wav").path
        let markdownURL = directory.appendingPathComponent("transcript.md")
        let viewModel = makeViewModel(session: session)
        let undoManager = UndoManager.forTests()

        undoManager.asOneEvent { _ = viewModel.renameSpeaker(id: "S2", to: "Zoltan", undoManager: undoManager) }
        #expect(try String(contentsOf: markdownURL, encoding: .utf8).contains("Zoltan"))

        undoManager.undo()
        #expect(!(try String(contentsOf: markdownURL, encoding: .utf8).contains("Zoltan")))

        undoManager.redo()
        #expect(try String(contentsOf: markdownURL, encoding: .utf8).contains("Zoltan"))
    }
}

extension TranscriptDetailViewModelTranscriptTests {
    @Test(arguments: [TranscriptPass.transcript, .retranscript])
    func linkedRenamesReplaceOneSharedSourceAndUndoEveryPart(pass: TranscriptPass) async throws {
        let f = try await LinkedSpeakersFixture(pass: pass)
        let store = try makeStore()
        let first = makeViewModel(session: f.parts[1], store: store)
        let second = makeViewModel(session: f.parts[2], store: store)
        let undo = UndoManager.forTests()
        let otherPass = f.parts.map { pass == .transcript ? $0.retranscriptData : $0.transcriptData }
        let originalManifest = try f.manifest()
        let originalRecords = f.parts.map(RecordingSessionRecord.init)
        let source = VoiceprintSource(sessionID: f.origin, pass: pass, speakerID: "S1")
        #expect(TranscriptDetailViewModel.voiceprintSource(for: "S1", of: f.parts[1]) == source)

        await undo.asOneEvent { first.renameSpeaker(id: "S1", to: "Ana", undoManager: undo) }?.value
        try f.expectNames("Ana", pass: pass)
        #expect(undo.undoActionName == UndoActionName.renameSpeaker)
        #expect(try await names(in: store) == ["Ana"])
        #expect(try await store.fetchAllSnapshots().map(\.sampleCount) == [2])
        #expect(try await store.snapshot(of: [source]).voiceprints.count == 2)

        // A different view model opened before the first edit must refresh its stale input.
        second.refreshTranscript()
        await undo.asOneEvent { second.renameSpeaker(id: "S1", to: "Bea", undoManager: undo) }?.value
        try f.expectNames("Bea", pass: pass)
        #expect(try await names(in: store) == ["Bea"])
        #expect(try await store.fetchAllSnapshots().map(\.sampleCount) == [2])
        #expect(f.parts.map { pass == .transcript ? $0.retranscriptData : $0.transcriptData } == otherPass)
        let renamedManifest = try f.manifest()
        #expect(pass == .transcript ? renamedManifest.retranscriptData == originalManifest.retranscriptData
            : renamedManifest.transcriptData == originalManifest.transcriptData)

        undo.undo()
        await second.speakerMemoryUpdate?.value
        try f.expectNames("Ana", pass: pass)
        #expect(try await names(in: store) == ["Ana"])
        undo.undo()
        await first.speakerMemoryUpdate?.value
        try f.expectNames("Speaker 1", pass: pass)
        #expect(f.parts.map(RecordingSessionRecord.init) == originalRecords)
        #expect(try f.manifest() == originalManifest)
        #expect(try await store.fetchAllSnapshots().isEmpty)
        #expect(!undo.canUndo)
        undo.redo()
        await first.speakerMemoryUpdate?.value
        try f.expectNames("Ana", pass: pass)
        undo.redo()
        await second.speakerMemoryUpdate?.value
        try f.expectNames("Bea", pass: pass)
        #expect(try await store.fetchAllSnapshots().map(\.sampleCount) == [2])
        let saved = ModelContext(f.container)
        for part in f.parts {
            let reloaded = try #require(try RecordingSession.fetch(id: part.id, in: saved))
            #expect(f.pass(of: reloaded, pass: pass)?.speakers.first?.label == "Bea")
        }
    }

    @Test(arguments: ["retranscribed", "differentOrigin", "differentGroup", "missingSpeaker", "held"])
    func linkedRenameSkipsMembersThatNoLongerShareItsSpeaker(reason: String) async throws {
        let f = try await LinkedSpeakersFixture(pass: .retranscript)
        let excluded = f.parts[1]
        var transcript = try #require(excluded.retranscript)
        var coordinator: SessionDeletionCoordinator?
        switch reason {
        case "retranscribed": transcript.spliceOriginSessionID = nil; excluded.retranscript = transcript
        case "differentOrigin": transcript.spliceOriginSessionID = UUID(); excluded.retranscript = transcript
        case "differentGroup": excluded.spliceGroupID = UUID()
        case "missingSpeaker": transcript.speakers.removeAll { $0.id == "S1" }; excluded.retranscript = transcript
        default:
            coordinator = f.coordinator()
            #expect(await coordinator!.delete(excluded, context: f.context, undoManager: nil) == .deleted)
        }
        try f.context.save()
        let before = reason == "held" ? nil : excluded.retranscriptData
        let heldBefore = reason == "held" ? try HoldingFolder(workspace: f.workspace).snapshotsForMembership() : []
        let vm = makeViewModel(session: f.parts[0], store: try makeStore())
        await vm.renameSpeaker(id: "S1", to: "Ana")?.value
        #expect(f.parts[0].retranscript?.speakers.first?.label == "Ana")
        #expect(f.parts[2].retranscript?.speakers.first?.label == "Ana")
        #expect(try f.manifestPass(.retranscript)?.speakers.first?.label == "Ana")
        if reason == "held" {
            #expect(try HoldingFolder(workspace: f.workspace).snapshotsForMembership() == heldBefore)
        } else { #expect(excluded.retranscriptData == before) }
    }

    @Test
    func linkedRenameUpdatesTheSamePassEvenWhenAnotherMemberDisplaysANewPass() async throws {
        let f = try await LinkedSpeakersFixture(pass: .transcript)
        let newPass = try #require(TranscriptSpeakerEditing.rename("S1", to: "Independent", in: teachableConversation()))
        f.parts[1].retranscript = newPass
        try writeTranscriptMarkdown(for: f.parts[1])
        try f.context.save()
        let before = f.parts[1].retranscriptData
        let vm = makeViewModel(session: f.parts[0])
        _ = vm.renameSpeaker(id: "S1", to: "Ana")
        #expect(f.parts[1].transcript?.speakers.first?.label == "Ana")
        #expect(f.parts[1].retranscriptData == before)
        #expect(try String(contentsOf: transcriptMarkdownURL(for: f.parts[1]), encoding: .utf8).contains("Independent"))
        #expect(TranscriptDetailViewModel.voiceprintSource(for: "S1", of: f.parts[1]).sessionID == f.parts[1].id)
    }

    @Test
    func mergeAndReassignmentAndTheirUndoStayInTheirOwnPart() async throws {
        let f = try await LinkedSpeakersFixture(pass: .transcript)
        let before = f.parts.map(\.transcriptData)
        let manifest = try Data(contentsOf: f.manifestURL)
        let first = makeViewModel(session: f.parts[0], store: try makeStore())
        let mergeUndo = UndoManager.forTests()
        await mergeUndo.asOneEvent { first.mergeSpeaker("S2", into: "S1", undoManager: mergeUndo) }?.value
        #expect(f.parts[0].transcript?.speakers.count == 1)
        #expect(f.parts[1].transcriptData == before[1] && f.parts[2].transcriptData == before[2])
        let second = makeViewModel(session: f.parts[1])
        let assignmentUndo = UndoManager.forTests()
        let block = try #require(second.blocks.first { $0.speaker.id == "S2" })
        assignmentUndo.asOneEvent { second.assign(block, to: "S1", undoManager: assignmentUndo) }
        #expect(f.parts[1].transcriptData != before[1])
        #expect(f.parts[2].transcriptData == before[2])
        #expect(try Data(contentsOf: f.manifestURL) == manifest)
        assignmentUndo.undo()
        mergeUndo.undo()
        await first.speakerMemoryUpdate?.value
        #expect(f.parts.map(\.transcript) == before.map { $0.flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) } })
        #expect(try Data(contentsOf: f.manifestURL) == manifest)
    }

    @Test
    func restoreKeepsTheNamesFromTheRenamedManifest() async throws {
        let f = try await LinkedSpeakersFixture(pass: .retranscript)
        let vm = makeViewModel(session: f.parts[1], store: try makeStore())
        let undo = UndoManager.forTests()
        await undo.asOneEvent { vm.renameSpeaker(id: "S1", to: "Ana", undoManager: undo) }?.value
        let target = f.parts[1]
        let coordinator = f.coordinator()
        let result = try await SpliceService().restore(session: target, workspace: f.workspace, context: f.context, coordinator: coordinator)
        #expect(result == SpliceService.RestoreResult())
        #expect(target.duration == 30)
        #expect(target.retranscript?.speakers.first?.label == "Ana")
        #expect(target.transcript?.speakers.first?.label == "Speaker 1")
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.mixdownURL!)) == LinkedSpeakersFixture.audio)
        #expect(!FileManager.default.fileExists(atPath: f.manifestURL.deletingLastPathComponent().path))
        undo.undo()
        await vm.speakerMemoryUpdate?.value
        #expect(target.retranscript?.speakers.first?.label == "Ana")
        #expect(try f.context.fetch(FetchDescriptor<RecordingSession>()).count == 1)
    }

    @Test(arguments: ["manifestMissing", "manifestCorrupt", "writeFirst", "writeManifest", "save", "reserved"])
    func linkedRenameFailureLeavesModelsFilesMemoryAndUndoUnchanged(reason: String) async throws {
        let f = try await LinkedSpeakersFixture(pass: .transcript)
        let store = try makeStore()
        if reason == "manifestMissing" { try FileManager.default.removeItem(at: f.manifestURL) }
        if reason == "manifestCorrupt" { try Data([0]).write(to: f.manifestURL) }
        let records = f.parts.map(RecordingSessionRecord.init)
        let disk = try f.disk()
        var written = 0
        var failed = false
        let vm = makeViewModel(session: f.parts[1], store: store, saveContext: { context in
            if reason == "save" { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }, writeSpeakerData: { data, url in
            try data.write(to: url, options: .atomic)
            written += 1
            if !failed && ((reason == "writeFirst" && written == 1) || (reason == "writeManifest" && url == f.manifestURL)) {
                failed = true
                throw CocoaError(.fileWriteUnknown)
            }
        })
        let undo = UndoManager.forTests()
        let registry = SpliceReservations.shared
        if reason == "reserved" { try registry.reserve(sessionID: f.parts[1].id, groupID: f.groupID) }
        let task = undo.asOneEvent { vm.renameSpeaker(id: "S1", to: "Ana", undoManager: undo) }
        if reason == "reserved" { registry.release(sessionID: f.parts[1].id, groupID: f.groupID) }
        await task?.value
        #expect(task == nil)
        #expect(undo.undoActionName.isEmpty)
        #expect(f.parts.map(RecordingSessionRecord.init) == records)
        #expect(try f.disk() == disk)
        #expect(try await store.fetchAllSnapshots().isEmpty)
        let saved = ModelContext(f.container)
        #expect(try saved.fetch(FetchDescriptor<RecordingSession>()).map(RecordingSessionRecord.init).sorted { $0.id.uuidString < $1.id.uuidString }
            == records.sorted { $0.id.uuidString < $1.id.uuidString })
    }
    @Test
    func queuedRenamesAndImmediateUndoFromDifferentPartsKeepMemoryInOrder() async throws {
        let f = try await LinkedSpeakersFixture(pass: .transcript)
        let store = try makeStore()
        let first = makeViewModel(session: f.parts[0], store: store)
        let undo = UndoManager.forTests()
        _ = undo.asOneEvent { first.renameSpeaker(id: "S1", to: "Ana", undoManager: undo) }
        let second = makeViewModel(session: f.parts[1], store: store)
        _ = undo.asOneEvent { second.renameSpeaker(id: "S1", to: "Bea", undoManager: undo) }
        undo.undo()
        undo.undo()
        await first.speakerMemoryUpdate?.value
        try f.expectNames("Speaker 1", pass: .transcript)
        #expect(try await store.fetchAllSnapshots().isEmpty)
        undo.redo()
        undo.redo()
        await second.speakerMemoryUpdate?.value
        try f.expectNames("Bea", pass: .transcript)
        #expect(try await names(in: store) == ["Bea"])
        #expect(try await store.fetchAllSnapshots().map(\.sampleCount) == [2])
    }

    @Test
    func retranscribedPartRenamesLocallyAndUndoOfALinkedEditLeavesItsNewPassAlone() async throws {
        let f = try await LinkedSpeakersFixture(pass: .retranscript)
        let store = try makeStore()
        let first = makeViewModel(session: f.parts[0], store: store)
        let undo = UndoManager.forTests()
        await undo.asOneEvent { first.renameSpeaker(id: "S1", to: "Ana", undoManager: undo) }?.value
        var independent = try #require(f.parts[1].retranscript)
        independent.spliceOriginSessionID = nil
        f.parts[1].retranscript = independent
        let second = makeViewModel(session: f.parts[1], store: store)
        await second.renameSpeaker(id: "S1", to: "Independent")?.value
        #expect(f.parts[0].retranscript?.speakers.first?.label == "Ana")
        #expect(try f.manifestPass(.retranscript)?.speakers.first?.label == "Ana")
        let changed = f.parts[1].retranscriptData
        undo.undo()
        await first.speakerMemoryUpdate?.value
        #expect(f.parts[0].retranscript?.speakers.first?.label == "Speaker 1")
        #expect(f.parts[2].retranscript?.speakers.first?.label == "Speaker 1")
        #expect(f.parts[1].retranscriptData == changed)
        #expect(try await names(in: store) == ["Independent"])
    }

    @Test
    func mergeAndResetInOnePartLeaveWhatTheGroupTaughtAlone() async throws {
        let f = try await LinkedSpeakersFixture(pass: .transcript)
        let store = try makeStore()
        let first = makeViewModel(session: f.parts[0], store: store)
        await first.renameSpeaker(id: "S1", to: "Ana")?.value
        let shared = VoiceprintSource(sessionID: f.origin, pass: .transcript, speakerID: "S1")
        let taught = try await store.snapshot(of: [shared]).voiceprints.map(\.embedding)
        #expect(taught.count == 2)

        await makeViewModel(session: f.parts[1], store: store).resetSpeaker("S1")?.value
        await makeViewModel(session: f.parts[2], store: store).mergeSpeaker("S1", into: "S2")?.value

        #expect(try await store.snapshot(of: [shared]).voiceprints.map(\.embedding) == taught)
        #expect(try await names(in: store) == ["Ana"])
        #expect(f.parts[0].transcript?.speakers.first?.label == "Ana")
    }
}

@MainActor
private final class LinkedSpeakersFixture {
    static let audio = Data("Original full audio".utf8)
    let workspace: Workspace
    let container: ModelContainer
    let context: ModelContext
    let origin: UUID
    let groupID: UUID
    let parts: [RecordingSession]
    var manifestURL: URL { workspace.rootURL.appendingPathComponent("splice/\(groupID.uuidString)/manifest.json") }

    init(pass: TranscriptPass) async throws {
        workspace = Workspace(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let folder = try RecordingFileLayout.createRecordingFolder(in: workspace, createdAt: .now)
        try Self.audio.write(to: folder.appendingPathComponent("recording.m4a"))
        container = try ModelContainer(for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        context.autosaveEnabled = false
        let session = RecordingSession(duration: 30, micAudioURL: folder.appendingPathComponent("mic.wav").path,
            mixdownURL: folder.appendingPathComponent("recording.m4a").path, title: "Original", status: .done)
        origin = session.id
        let times: [(String, Float, Float)] = [("S1", 0, 2), ("S2", 3, 4), ("S1", 8, 10), ("S2", 13, 14),
            ("S1", 18, 20), ("S2", 23, 24), ("S1", 28, 30)]
        var transcript = Transcript(fullText: "Words", segments: times.map {
            TranscriptSegment(speakerId: $0.0, text: "Words", startTime: $0.1, endTime: $0.2)
        }, speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "112233"),
                      TranscriptSpeaker(id: "S2", label: "Speaker 2", colorHex: "445566")])
        transcript.voiceprintSpace = VoiceprintSpace.current
        transcript.speakerVoiceprints = ["S1": [[1, 0], [0.8, 0.2]], "S2": [[0, 1]]]
        session.transcript = transcript
        if pass == .retranscript { session.retranscript = transcript }
        context.insert(session)
        try context.save()
        parts = try await SpliceService(capacityProvider: { _ in .max }, export: { from, to, start, end in
            try (Data("\(start)..\(end):".utf8) + Data(contentsOf: from)).write(to: to)
        }).splice(session: session, plan: SplicePlan(cuts: [11.5, 21.5],
            parts: [.init(title: "One"), .init(title: "Two"), .init(title: "Three")],
            transcriptFingerprint: SplicePlan.fingerprint(transcriptData: session.transcriptData, retranscriptData: session.retranscriptData)),
            workspace: workspace, context: context)
        groupID = try #require(session.spliceGroupID)
    }
    deinit { try? FileManager.default.removeItem(at: workspace.rootURL) }
    func pass(of session: RecordingSession, pass: TranscriptPass) -> Transcript? {
        pass == .transcript ? session.transcript : session.retranscript
    }
    func manifest() throws -> SpliceManifest { try JSONDecoder().decode(SpliceManifest.self, from: Data(contentsOf: manifestURL)) }
    func manifestPass(_ pass: TranscriptPass) throws -> Transcript? {
        let manifest = try manifest()
        return try (pass == .transcript ? manifest.transcriptData : manifest.retranscriptData).map { try JSONDecoder().decode(Transcript.self, from: $0) }
    }
    func expectNames(_ name: String, pass: TranscriptPass) throws {
        #expect(parts.allSatisfy { self.pass(of: $0, pass: pass)?.speakers.first?.label == name })
        #expect(try manifestPass(pass)?.speakers.first?.label == name)
        for part in parts { #expect(try String(contentsOf: transcriptMarkdownURL(for: part), encoding: .utf8).contains(name)) }
    }
    func coordinator() -> SessionDeletionCoordinator {
        SessionDeletionCoordinator(workspaceService: ReconciliationWorkspace(workspace: workspace), announce: { _ in },
            startAccess: { _ in false }, stopAccess: { _ in }, scheduleExpiry: { _, _ in AnyCancellable {} })
    }
    func disk() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = try #require(FileManager.default.enumerator(at: workspace.rootURL, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(workspace.rootURL.path.count))] = try Data(contentsOf: file)
        }
        return result
    }
}
