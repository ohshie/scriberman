import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// Opening a search result: the study view arrives with the query applied and the matched block
/// selected, and nothing starts playing.
@MainActor
struct TranscriptStudySearchSeedTests {
    private func blocks(_ lines: [String]) -> [TranscriptBlock] {
        lines.enumerated().map { index, line in
            TranscriptBlock(
                speaker: TranscriptSpeaker(id: "speaker-\(index)", label: "Speaker", colorHex: "#112233"),
                audioSource: .mic,
                startTime: Float(index),
                endTime: Float(index) + 1,
                text: line
            )
        }
    }

    // MARK: - Selecting the seeded match

    @Test
    func testSelectingAMatchByBlockMovesOffTheFirstMatch() {
        let blocks = blocks([
            "the migration is mentioned here first",
            "and the migration again later",
        ])
        let state = TranscriptSearchState()
        state.query = "migration"
        state.update(blocks: blocks)

        #expect(state.currentMatch?.blockID == blocks[0].id)

        state.selectFirstMatch(inBlock: blocks[1].id)

        #expect(state.currentMatch?.blockID == blocks[1].id)
        // The highlight the study view draws comes from the same selection.
        #expect(state.activeRange(in: blocks[1]) != nil)
        #expect(state.activeRange(in: blocks[0]) == nil)
    }

    @Test
    func testSelectingABlockWithNoMatchLeavesTheSelectionAlone() {
        let blocks = blocks([
            "the migration is mentioned here",
            "nothing relevant in this one",
        ])
        let state = TranscriptSearchState()
        state.query = "migration"
        state.update(blocks: blocks)

        state.selectFirstMatch(inBlock: blocks[1].id)

        #expect(state.currentMatch?.blockID == blocks[0].id)
    }

    @Test
    func testTwoSeedsForTheSameMatchAreDifferentValues() {
        let blockID = UUID()
        let first = TranscriptStudySearchSeed(query: "migration", blockID: blockID)
        let second = TranscriptStudySearchSeed(query: "migration", blockID: blockID)

        // Clicking the same result again has to move the view again, so the seed must not compare
        // equal to the one already applied.
        #expect(first != second)
    }

    // MARK: - The view's wiring

    @Test(.tags(.sourceLint))
    func testTheSeedIsAppliedFromATaskKeyedOnIt() throws {
        let source = try studyViewSource()

        #expect(source.contains(".task(id: searchSeed)"))
        #expect(source.contains("applySearchSeed()"))
    }

    @Test(.tags(.sourceLint))
    func testApplyingASeedSelectsTheMatchAndScrollsToIt() throws {
        let body = try #require(functionBody(named: "private func applySearchSeed()", in: try studyViewSource()))

        #expect(body.contains("searchState.query = searchSeed.query"))
        #expect(body.contains("searchState.selectFirstMatch(inBlock: blockID)"))
        #expect(body.contains("scrollTargetID = searchState.currentMatch?.blockID"))
        #expect(body.contains("isSearchVisible = true"))
    }

    /// Opening a session that was not reached by search leaves the view exactly as it was: empty
    /// find bar, no match, nothing hidden.
    @Test(.tags(.sourceLint))
    func testNoSeedLeavesTheViewUnchanged() throws {
        let body = try #require(functionBody(named: "private func applySearchSeed()", in: try studyViewSource()))

        #expect(body.contains("guard let searchSeed, !searchSeed.query.isEmpty else { return }"))
    }

    /// Locating text and listening to it are separate intentions.
    @Test(.tags(.sourceLint))
    func testApplyingASeedStartsNoPlayback() throws {
        let body = try #require(functionBody(named: "private func applySearchSeed()", in: try studyViewSource()))

        #expect(!body.contains("audioPlayerViewModel"))
        #expect(!body.contains(".play()"))
    }

    @Test(.tags(.sourceLint))
    func testOpeningAResultStartsNoPlayback() throws {
        let body = try #require(functionBody(named: "private func openSearchResult(", in: try appShellSource()))

        #expect(!body.contains(".play()"))
    }

    /// A seeded search is dismissed by the same path as one the user opened, so Escape behaves the
    /// same either way.
    @Test(.tags(.sourceLint))
    func testASeededSearchIsDismissedLikeAnyOther() throws {
        let source = try studyViewSource()
        let dismiss = try #require(functionBody(named: "private func dismissSearch()", in: source))

        #expect(dismiss.contains("searchState.query = \"\""))
        #expect(dismiss.contains("isSearchVisible = false"))
        // The find bar's own Escape shortcut calls that one dismissal.
        #expect(source.contains("TranscriptFindBar(searchState: searchState) {"))
    }

    /// Clicking a result whose session is already selected changes no binding, so the row reports
    /// the click itself.
    @Test(.tags(.sourceLint))
    func testAClickOnAResultIsReportedEvenWithoutASelectionChange() throws {
        let source = try readSourceFile(relativePathFromTests: "../UI/JobsView.swift")

        #expect(source.contains("TapGesture().onEnded { onOpenSearchResult(item) }"))
        // Masked off when nothing is being searched, so it cannot compete with the row's own
        // click-to-select.
        #expect(source.contains("including: viewModel.activeSearchQuery != nil ? .all : .none"))
    }

    /// The selection change handler resets the detail view. Without this guard it would undo the
    /// navigation that caused the change.
    @Test(.tags(.sourceLint))
    func testSelectingAResultIsNotResetByTheSelectionHandler() throws {
        let source = try appShellSource()

        #expect(source.contains("let isOpeningSearchResult = newValue != nil && newValue?.id == studySearchSeedItemID"))
        #expect(source.contains("guard !isOpeningSearchResult else { return }"))
    }

    // MARK: - Helpers

    private func studyViewSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../UI/TranscriptStudyView.swift")
    }

    private func appShellSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../UI/AppShellView.swift")
    }

    private func functionBody(named declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }

    private func readSourceFile(relativePathFromTests: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent(relativePathFromTests),
            encoding: .utf8
        )
    }

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
        let renamed = try #require(TranscriptStudyView.renameSpeaker(id: "S1", to: "Ana", in: shownForB, of: sessionB))

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
        _ = TranscriptStudyView.renameSpeaker(id: "S1", to: "Ana", in: shown, of: session)

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
        session.transcript = original

        let renamed = try #require(TranscriptStudyView.renameSpeaker(id: "S1", to: "Ana", in: original, of: session))

        #expect(renamed.speakerEmbeddings == ["S1": [0.5]])
        #expect(renamed.speakerProfileIDs == ["S1": profileID])
    }

    @Test
    func testRenamingAnUnknownSpeakerWritesNothing() {
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/d/mic.wav", title: "D")
        session.transcript = transcript(text: "words", speakerLabel: "Speaker 1")
        let before = session.transcriptData

        let result = TranscriptStudyView.renameSpeaker(id: "missing", to: "Ana", in: session.transcript!, of: session)

        #expect(result == nil)
        #expect(session.transcriptData == before)
    }

    // MARK: - Rename into speaker memory

    private func makeStore() throws -> SpeakerEmbeddingStore {
        let container = try ModelContainer(
            for: SpeakerProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return SpeakerEmbeddingStore(modelContainer: container)
    }

    private func liveTranscript(voiceprint: [Float], linkedTo profileID: UUID?) -> Transcript {
        var transcript = transcript(text: "words", speakerLabel: "Speaker 1")
        transcript.speakerEmbeddings = ["S1": voiceprint]
        transcript.speakerProfileIDs = profileID.map { ["S1": $0] }
        return transcript
    }

    private func names(in store: SpeakerEmbeddingStore) async throws -> Set<String> {
        Set(try await store.fetchAllSnapshots().map(\.name))
    }

    @Test
    func testRenamingALinkedSpeakerRenamesItsProfile() async throws {
        let store = try makeStore()
        let linkedID = try await store.enrollNamedSpeaker(name: "Speaker 5", embedding: [0.5])

        let unlinked = try await TranscriptStudyView.updateSpeakerMemory(
            forRenaming: "S1", to: "Bob", in: liveTranscript(voiceprint: [0.5], linkedTo: linkedID), store: store
        )

        #expect(unlinked == false)
        #expect(try await names(in: store) == ["Bob"])
        #expect(try await store.findProfileSnapshot(byID: linkedID)?.name == "Bob")
    }

    @Test
    func testRenamingALinkedSpeakerToAnExistingNameMergesAndUnlinks() async throws {
        let store = try makeStore()
        let aliceID = try await store.enrollNamedSpeaker(name: "Alice", embedding: [0.1])
        let linkedID = try await store.enrollNamedSpeaker(name: "Speaker 5", embedding: [0.5])
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/f/mic.wav", title: "F")
        let original = liveTranscript(voiceprint: [0.5], linkedTo: linkedID)
        session.transcript = original

        let unlinked = try await TranscriptStudyView.updateSpeakerMemory(
            forRenaming: "S1", to: "alice", in: original, store: store
        )
        let updated = TranscriptStudyView.removingProfileLink(for: "S1", in: original, of: session)

        #expect(unlinked)
        #expect(try await names(in: store) == ["Alice"])
        #expect(try await store.findProfileSnapshot(byID: aliceID)?.embedding == [0.5])
        #expect(try await store.findProfileSnapshot(byID: linkedID) == nil)
        #expect(updated?.speakerProfileIDs == nil)
        #expect(session.transcript?.speakerProfileIDs == nil)
        #expect(session.transcript?.speakerEmbeddings == ["S1": [0.5]])
    }

    @Test
    func testRenamingTwiceAfterAMergeLeavesTheExistingProfileNamed() async throws {
        let store = try makeStore()
        let aliceID = try await store.enrollNamedSpeaker(name: "Alice", embedding: [0.1])
        let linkedID = try await store.enrollNamedSpeaker(name: "Speaker 5", embedding: [0.5])
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/g/mic.wav", title: "G")
        let original = liveTranscript(voiceprint: [0.5], linkedTo: linkedID)
        session.transcript = original

        _ = try await TranscriptStudyView.updateSpeakerMemory(forRenaming: "S1", to: "Alice", in: original, store: store)
        let afterMerge = try #require(TranscriptStudyView.removingProfileLink(for: "S1", in: original, of: session))
        let unlinkedAgain = try await TranscriptStudyView.updateSpeakerMemory(
            forRenaming: "S1", to: "Carol", in: afterMerge, store: store
        )

        #expect(unlinkedAgain == false)
        #expect(try await store.findProfileSnapshot(byID: aliceID)?.name == "Alice")
        #expect(try await names(in: store) == ["Alice", "Carol"])
        let carolID = try #require(try await store.profileID(forName: "Carol"))
        #expect(try await store.findProfileSnapshot(byID: carolID)?.embedding == [0.5])
    }

    @Test
    func testRenamingASpeakerWhoseLinkedProfileWasDeletedEnrollsByName() async throws {
        let store = try makeStore()
        let deletedID = try await store.enrollNamedSpeaker(name: "Speaker 5", embedding: [0.5])
        try await store.deleteProfile(id: deletedID)

        let unlinked = try await TranscriptStudyView.updateSpeakerMemory(
            forRenaming: "S1", to: "Bob", in: liveTranscript(voiceprint: [0.5], linkedTo: deletedID), store: store
        )

        #expect(unlinked == false)
        #expect(try await names(in: store) == ["Bob"])
        let bobID = try #require(try await store.profileID(forName: "Bob"))
        #expect(try await store.findProfileSnapshot(byID: bobID)?.embedding == [0.5])
    }

    @Test
    func testRenamingAMatchedSpeakerKeepsTheMatchedProfileName() async throws {
        let store = try makeStore()
        let aliceID = try await store.enrollNamedSpeaker(name: "Alice", embedding: [0.1])

        _ = try await TranscriptStudyView.updateSpeakerMemory(
            forRenaming: "S1", to: "Carol", in: liveTranscript(voiceprint: [0.1], linkedTo: nil), store: store
        )

        #expect(try await store.findProfileSnapshot(byID: aliceID)?.name == "Alice")
        #expect(try await names(in: store) == ["Alice", "Carol"])
    }

    private func transcript(text: String, speakerLabel: String) -> Transcript {
        Transcript(
            fullText: text,
            segments: [TranscriptSegment(speakerId: "S1", text: text, startTime: 0, endTime: 1)],
            speakers: [TranscriptSpeaker(id: "S1", label: speakerLabel, colorHex: "#112233")]
        )
    }
}
