import Foundation
import Testing
@testable import Scriberman

struct TranscriptSpeakerEditingTests {
    private func segment(_ speakerID: String, _ text: String, _ start: Float, _ end: Float, source: AudioSource = .mic) -> TranscriptSegment {
        TranscriptSegment(speakerId: speakerID, text: text, startTime: start, endTime: end, audioSource: source)
    }

    private func speaker(_ id: String, _ label: String) -> TranscriptSpeaker {
        TranscriptSpeaker(id: id, label: label, colorHex: "#111111")
    }

    private func transcript(_ segments: [TranscriptSegment], _ speakers: [TranscriptSpeaker]) -> Transcript {
        Transcript(
            fullText: Transcript.fullText(joining: segments),
            segments: segments,
            speakers: speakers,
            voiceprintSpace: VoiceprintSpace.current
        )
    }

    @Test(arguments: [
        ("Speaker 1", true), ("Speaker 12", true), ("Speaker 0", false), ("Speaker 01", false),
        ("Speaker -1", false), ("Speaker", false), ("speaker 1", false), ("Speaker 1a", false), ("Alice", false)
    ])
    func unnamedLabels(label: String, unnamed: Bool) {
        #expect(TranscriptSpeakerEditing.isUnnamed(label: label) == unnamed)
    }

    @Test
    func renameChangesOnlyTheLabel() throws {
        var original = transcript([segment("S1", "hi", 0, 1)], [speaker("S1", "Speaker 1")])
        original.speakerVoiceprints = ["S1": [[1, 0]]]

        let renamed = try #require(TranscriptSpeakerEditing.rename("S1", to: "Bob", in: original))

        #expect(renamed.speakers.map(\.label) == ["Bob"])
        #expect(renamed.segments == original.segments)
        #expect(renamed.speakerVoiceprints == original.speakerVoiceprints)
        #expect(renamed.voiceprintSpace == VoiceprintSpace.current)
        #expect(TranscriptSpeakerEditing.rename("missing", to: "Bob", in: original) == nil)
    }

    /// Spec scenario "Two IDs for one person".
    @Test
    func mergeMovesSegmentsAndVoiceprints() throws {
        var original = transcript(
            [segment("A", "one", 0, 1), segment("S3", "two", 1, 2), segment("S2", "three", 2, 3)],
            [speaker("A", "Alice"), speaker("S2", "Speaker 2"), speaker("S3", "Speaker 3")]
        )
        original.speakerVoiceprints = ["A": [[1, 0]], "S3": [[0, 1]], "S2": [[0.5, 0.5]]]

        let merged = try #require(TranscriptSpeakerEditing.merge("S3", into: "A", in: original))

        #expect(merged.segments.map(\.speakerId) == ["A", "A", "S2"])
        #expect(merged.segments.map(\.id) == original.segments.map(\.id))
        #expect(merged.speakers.map(\.label) == ["Alice", "Speaker 2"])
        #expect(merged.speakerVoiceprints?["A"] == [[1, 0], [0, 1]])
        #expect(merged.speakerVoiceprints?["S3"] == nil)
        #expect(merged.speakerVoiceprints?["S2"] == [[0.5, 0.5]])
    }

    @Test
    func mergeIntoItselfOrAMissingSpeakerChangesNothing() {
        let original = transcript([segment("A", "one", 0, 1)], [speaker("A", "Alice")])
        #expect(TranscriptSpeakerEditing.merge("A", into: "A", in: original) == nil)
        #expect(TranscriptSpeakerEditing.merge("A", into: "B", in: original) == nil)
    }

    /// Spec scenario "Adjacent blocks join".
    @Test
    func mergedAdjacentBlocksJoin() throws {
        let original = transcript(
            [segment("A", "one", 0, 1), segment("S3", "two", 1, 2), segment("A", "three", 2, 3)],
            [speaker("A", "Alice"), speaker("S3", "Speaker 3")]
        )
        #expect(TranscriptGrouper.makeBlocks(from: original).count == 3)

        let merged = try #require(TranscriptSpeakerEditing.merge("S3", into: "A", in: original))

        let blocks = TranscriptGrouper.makeBlocks(from: merged)
        #expect(blocks.count == 1)
        #expect(blocks.first?.speaker.label == "Alice")
        #expect(blocks.first?.segmentIDs == original.segments.map(\.id))
    }

    /// Spec scenario "Wrong name undone": the reset label is the smallest free `Speaker N`.
    @Test
    func resetUsesTheSmallestFreeNumber() throws {
        let original = transcript(
            [segment("S1", "one", 0, 1), segment("S2", "two", 1, 2)],
            [speaker("S1", "Speaker 1"), speaker("S2", "Bob")]
        )

        let reset = try #require(TranscriptSpeakerEditing.reset("S2", in: original))

        #expect(reset.speakers.map(\.label) == ["Speaker 1", "Speaker 2"])
    }

    @Test
    func resetOfASpeakerAlreadyUnnamedMayKeepItsLabel() throws {
        let original = transcript([segment("S1", "one", 0, 1)], [speaker("S1", "Speaker 1")])
        #expect(try #require(TranscriptSpeakerEditing.reset("S1", in: original)).speakers.map(\.label) == ["Speaker 1"])
    }

    /// Spec scenario "One block moved".
    @Test
    func reassignMovesOnlyTheChosenBlock() throws {
        var original = transcript(
            [segment("A", "one", 0, 1), segment("B", "x", 1, 2), segment("A", "two", 2, 3),
             segment("B", "y", 3, 4), segment("A", "three", 4, 5)],
            [speaker("A", "Alice"), speaker("B", "Bob")]
        )
        original.speakerVoiceprints = ["A": [[1, 0]], "B": [[0, 1]]]
        let blocks = TranscriptGrouper.makeBlocks(from: original)
        let second = blocks.filter { $0.speaker.id == "A" }[1]

        let edited = TranscriptSpeakerEditing.reassign(segmentIDs: Set(second.segmentIDs), to: "B", in: original)

        let labels = TranscriptGrouper.makeBlocks(from: edited).map(\.speaker.label)
        #expect(labels == ["Alice", "Bob", "Alice"])
        #expect(edited.speakers == original.speakers)
        #expect(edited.speakerVoiceprints == original.speakerVoiceprints)
    }

    /// Spec scenario "New speaker".
    @Test
    func newSpeakerTakesTheSmallestFreeNumber() throws {
        let original = transcript(
            [segment("A", "one", 0, 1), segment("S2", "two", 1, 2), segment("A", "three", 2, 3)],
            [speaker("A", "Alice"), speaker("S2", "Speaker 2")]
        )
        let (added, newID) = TranscriptSpeakerEditing.addSpeaker(to: original)
        let edited = TranscriptSpeakerEditing.reassign(segmentIDs: [original.segments[0].id], to: newID, in: added)

        let blocks = TranscriptGrouper.makeBlocks(from: edited)
        #expect(blocks.first?.speaker.label == "Speaker 1")
        #expect(edited.speakers.last?.id == newID)
        #expect(edited.speakerVoiceprints?[newID] == nil)
        #expect(!original.speakers.map(\.id).contains(newID))
    }

    /// Spec scenario "New speaker after a removal".
    @Test
    func newSpeakerFillsAGap() {
        let original = transcript(
            [segment("S1", "one", 0, 1), segment("S3", "two", 1, 2)],
            [speaker("S1", "Speaker 1"), speaker("S3", "Speaker 3")]
        )
        let (added, newID) = TranscriptSpeakerEditing.addSpeaker(to: original)
        #expect(added.speakers.first { $0.id == newID }?.label == "Speaker 2")
    }

    /// Spec scenario "Last block of a speaker moved away".
    @Test
    func speakerWithNoBlocksLeftIsRemoved() {
        let original = transcript(
            [segment("A", "one", 0, 1), segment("S4", "two", 1, 2)],
            [speaker("A", "Alice"), speaker("S4", "Speaker 4")]
        )

        let edited = TranscriptSpeakerEditing.reassign(segmentIDs: [original.segments[1].id], to: "A", in: original)

        #expect(edited.speakers.map(\.label) == ["Alice"])
    }

    // MARK: - Session speaker list

    /// Spec scenario "List contents".
    @Test
    func speakerListSumsTalkTimeAndMarksMatches() {
        let original = transcript(
            [segment("A", "one", 0, 400), segment("S2", "two", 400, 762), segment("A", "three", 762, 1062)],
            [speaker("A", "Alice"), speaker("S2", "Speaker 2")]
        )
        let alice = SpeakerProfileSnapshot(profile: SpeakerProfile(name: "alice", embedding: [1]))

        let rows = SessionSpeakerList.rows(for: original, profiles: [alice])

        #expect(rows.map(\.speaker.label) == ["Alice", "Speaker 2"])
        #expect(rows.map(\.isMatched) == [true, false])
        #expect(rows.map(\.talkTime) == [700, 362])
        #expect(rows.map { TimeFormatter.format(seconds: $0.talkTime) } == ["11:40", "06:02"])
        #expect(rows.map(\.audioSource) == [.mic, .mic])
    }

    @Test
    func resetIsEnabledOnlyForNamedSpeakers() {
        let original = transcript(
            [segment("A", "one", 0, 1), segment("S3", "two", 1, 2)],
            [speaker("A", "Alice"), speaker("S3", "Speaker 3")]
        )
        #expect(SessionSpeakerList.rows(for: original, profiles: []).map(\.canReset) == [true, false])
    }
}
