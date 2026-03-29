import XCTest
@testable import Scriberman

final class TranscriptGrouperTests: XCTestCase {
    func testMakeBlocksMergesConsecutiveSegmentsWithSameSpeakerAndSource() {
        let transcript = Transcript(
            fullText: "Hello world",
            segments: [
                TranscriptSegment(speakerId: "S1", text: " Hello ", startTime: 0.0, endTime: 1.0, audioSource: .mic),
                TranscriptSegment(speakerId: "S1", text: "world", startTime: 1.0, endTime: 2.0, audioSource: .mic)
            ],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")]
        )

        let blocks = TranscriptGrouper.makeBlocks(from: transcript)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].speaker.id, "S1")
        XCTAssertEqual(blocks[0].audioSource, .mic)
        XCTAssertEqual(blocks[0].startTime, 0.0)
        XCTAssertEqual(blocks[0].endTime, 2.0)
        XCTAssertEqual(blocks[0].text, "Hello world")
    }

    func testMakeBlocksSplitsWhenAudioSourceDiffers() {
        let transcript = Transcript(
            fullText: "A B",
            segments: [
                TranscriptSegment(speakerId: "S1", text: "A", startTime: 0.0, endTime: 1.0, audioSource: .mic),
                TranscriptSegment(speakerId: "S1", text: "B", startTime: 1.0, endTime: 2.0, audioSource: .app)
            ],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")]
        )

        let blocks = TranscriptGrouper.makeBlocks(from: transcript)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].audioSource, .mic)
        XCTAssertEqual(blocks[1].audioSource, .app)
    }

    func testMakeBlocksUsesFallbackSpeakerWhenSpeakerIsMissing() {
        let transcript = Transcript(
            fullText: "Unknown",
            segments: [
                TranscriptSegment(speakerId: "missing", text: "Unknown", startTime: 0.0, endTime: 1.0, audioSource: .mic)
            ],
            speakers: []
        )

        let blocks = TranscriptGrouper.makeBlocks(from: transcript)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].speaker.id, "missing")
        XCTAssertEqual(blocks[0].speaker.label, "missing")
        XCTAssertEqual(blocks[0].speaker.colorHex, "#6B7280")
    }
}
