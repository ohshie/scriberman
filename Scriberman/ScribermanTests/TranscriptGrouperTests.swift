import Testing
@testable import Scriberman

struct TranscriptGrouperTests {
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
}
