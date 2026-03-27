import FluidAudio
import XCTest
@testable import Scriberman

final class TranscriptAlignerTests: XCTestCase {
    private let aligner = TranscriptAligner()

    func testAlignWithTokensAndDiarizedSegmentsProducesMappedTranscript() {
        let transcript = aligner.alignTranscript(
            fullText: "hello world",
            tokenTimings: [
                token("▁hello", start: 0.00, end: 0.40),
                token("▁world", start: 0.60, end: 1.00)
            ],
            diarizedSegments: [
                segment("S1", start: 0.0, end: 0.5),
                segment("S2", start: 0.5, end: 1.1)
            ]
        )

        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0], TranscriptSegment(speakerId: "S1", text: "hello", startTime: 0.0, endTime: 0.5))
        XCTAssertEqual(transcript.segments[1], TranscriptSegment(speakerId: "S2", text: "world", startTime: 0.5, endTime: 1.1))
        XCTAssertEqual(transcript.fullText, "hello world")
        XCTAssertEqual(transcript.speakers.map(\.colorHex), ["#4F46E5", "#16A34A"])
    }

    func testEmptyTokensAndEmptyDiarizedSegmentsUseSingleFallbackSegment() {
        let transcript = aligner.alignTranscript(
            fullText: "fallback text",
            tokenTimings: [],
            diarizedSegments: []
        )

        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].speakerId, "S1")
        XCTAssertEqual(transcript.segments[0].text, "fallback text")
    }

    func testEmptyTokensWithDiarizedSegmentsUsesFirstSpeaker() {
        let transcript = aligner.alignTranscript(
            fullText: "speaker fallback",
            tokenTimings: [],
            diarizedSegments: [
                segment("S2", start: 10.0, end: 12.0),
                segment("S3", start: 12.0, end: 16.0)
            ]
        )

        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].speakerId, "S2")
        XCTAssertEqual(transcript.segments[0].startTime, 10.0)
        XCTAssertEqual(transcript.segments[0].endTime, 16.0)
    }

    func testSegmentsWithNoOverlappingTokensAreDropped() {
        let transcript = aligner.alignTranscript(
            fullText: "unused",
            tokenTimings: [token("▁hello", start: 0.0, end: 0.2)],
            diarizedSegments: [
                segment("S1", start: 0.0, end: 0.3),
                segment("S2", start: 0.8, end: 1.2)
            ]
        )

        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].speakerId, "S1")
        XCTAssertEqual(transcript.speakers.count, 1)
    }

    func testSpeakerColorPaletteMethod() {
        XCTAssertEqual(aligner.speakerColorHex(at: 0), "#4F46E5")
        XCTAssertEqual(aligner.speakerColorHex(at: 1), "#16A34A")
        XCTAssertEqual(aligner.speakerColorHex(at: 6), "#4F46E5")
    }

    private func token(_ piece: String, start: TimeInterval, end: TimeInterval) -> TokenTiming {
        TokenTiming(token: piece, tokenId: 0, startTime: start, endTime: end, confidence: 1.0)
    }

    private func segment(_ speakerId: String, start: Float, end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerId,
            embedding: [],
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 1.0
        )
    }
}
