import Testing
@testable import Scriberman

struct TranscriptGrouperTests {
    private let speaker = TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")

    @Test
    func makeBlocksMergesConsecutiveSegmentsWithSameSpeakerAndSource() {
        let transcript = Transcript(
            fullText: "Hello world",
            segments: [
                TranscriptSegment(speakerId: "S1", text: " Hello ", startTime: 0.0, endTime: 1.0, audioSource: .mic),
                TranscriptSegment(speakerId: "S1", text: "world", startTime: 1.0, endTime: 2.0, audioSource: .mic)
            ],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")]
        )

        let blocks = TranscriptGrouper.makeBlocks(from: transcript)

        #expect(blocks.count == 1)
        #expect(blocks[0].speaker.id == "S1")
        #expect(blocks[0].audioSource == .mic)
        #expect(blocks[0].startTime == 0.0)
        #expect(blocks[0].endTime == 2.0)
        #expect(blocks[0].text == "Hello world")
    }

    @Test
    func makeBlocksSplitsWhenAudioSourceDiffers() {
        let transcript = Transcript(
            fullText: "A B",
            segments: [
                TranscriptSegment(speakerId: "S1", text: "A", startTime: 0.0, endTime: 1.0, audioSource: .mic),
                TranscriptSegment(speakerId: "S1", text: "B", startTime: 1.0, endTime: 2.0, audioSource: .app)
            ],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")]
        )

        let blocks = TranscriptGrouper.makeBlocks(from: transcript)

        #expect(blocks.count == 2)
        #expect(blocks[0].audioSource == .mic)
        #expect(blocks[1].audioSource == .app)
    }

    @Test
    func makeBlocksUsesFallbackSpeakerWhenSpeakerIsMissing() {
        let transcript = Transcript(
            fullText: "Unknown",
            segments: [
                TranscriptSegment(speakerId: "missing", text: "Unknown", startTime: 0.0, endTime: 1.0, audioSource: .mic)
            ],
            speakers: []
        )

        let blocks = TranscriptGrouper.makeBlocks(from: transcript)

        #expect(blocks.count == 1)
        #expect(blocks[0].speaker.id == "missing")
        #expect(blocks[0].speaker.label == "missing")
        #expect(blocks[0].speaker.colorHex == "#6B7280")
    }

    @Test
    @MainActor
    func activeBlockSelectsCorrectBlockForBoundariesAndGaps() {
        let blocks = [
            TranscriptBlock(speaker: speaker, audioSource: .mic, startTime: 0, endTime: 2, text: "A"),
            TranscriptBlock(speaker: speaker, audioSource: .mic, startTime: 2, endTime: 3, text: "B"),
            TranscriptBlock(speaker: speaker, audioSource: .mic, startTime: 4, endTime: 5, text: "C")
        ]

        #expect(TranscriptStudyView.activeBlock(for: blocks, currentTime: 0)?.text == "A")
        #expect(TranscriptStudyView.activeBlock(for: blocks, currentTime: 1.999)?.text == "A")
        #expect(TranscriptStudyView.activeBlock(for: blocks, currentTime: 2)?.text == "B")
        #expect(TranscriptStudyView.activeBlock(for: blocks, currentTime: 3) == nil)
        #expect(TranscriptStudyView.activeBlock(for: blocks, currentTime: 4)?.text == "C")
    }

    @Test
    @MainActor
    func activeBlockReturnsNilOutsideBlockRanges() {
        let blocks = [
            TranscriptBlock(speaker: speaker, audioSource: .mic, startTime: 1, endTime: 2, text: "A")
        ]

        #expect(TranscriptStudyView.activeBlock(for: blocks, currentTime: 0.5) == nil)
        #expect(TranscriptStudyView.activeBlock(for: blocks, currentTime: 2.0) == nil)
        #expect(TranscriptStudyView.activeBlock(for: blocks, currentTime: 10.0) == nil)
    }
}
