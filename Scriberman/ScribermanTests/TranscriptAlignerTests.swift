import FluidAudio
import Foundation
import Testing
@testable import Scriberman

struct TranscriptAlignerTests {
    private let aligner = TranscriptAligner()

    @Test
    func alignWithTokensAndDiarizedSegmentsProducesMappedTranscript() {
        let transcript = aligner.alignTranscript(
            fullText: "hello world",
            tokenTimings: [
                token("▁hello", start: 0.00, end: 0.40),
                token("▁world", start: 0.60, end: 1.00)
            ],
            diarizedSegments: [
                segment("S1", start: 0.0, end: 0.5),
                segment("S2", start: 0.5, end: 1.1)
            ],
            source: .mic
        )

        #expect(transcript.segments.count == 2)
        #expect(transcript.segments[0].speakerId == "S1")
        #expect(transcript.segments[0].text == "hello")
        #expect(transcript.segments[0].startTime == 0.0)
        #expect(transcript.segments[0].endTime == 0.5)

        #expect(transcript.segments[1].speakerId == "S2")
        #expect(transcript.segments[1].text == "world")
        #expect(transcript.segments[1].startTime == 0.5)
        #expect(transcript.segments[1].endTime == 1.1)

        #expect(transcript.fullText == "hello world")
        #expect(transcript.speakers.map { $0.colorHex } == ["#4F46E5", "#16A34A"])
    }

    @Test
    func emptyTokensAndEmptyDiarizedSegmentsUseSingleFallbackSegment() {
        let transcript = aligner.alignTranscript(
            fullText: "fallback text",
            tokenTimings: [],
            diarizedSegments: [],
            source: .mic
        )

        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].speakerId == "S1")
        #expect(transcript.segments[0].text == "fallback text")
    }

    @Test
    func emptyTokensWithDiarizedSegmentsUsesFirstSpeaker() {
        let transcript = aligner.alignTranscript(
            fullText: "speaker fallback",
            tokenTimings: [],
            diarizedSegments: [
                segment("S2", start: 10.0, end: 12.0),
                segment("S3", start: 12.0, end: 16.0)
            ],
            source: .mic
        )

        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].speakerId == "S2")
        #expect(transcript.segments[0].startTime == 10.0)
        #expect(transcript.segments[0].endTime == 16.0)
    }

    @Test
    func segmentsWithNoOverlappingTokensAreDropped() {
        let transcript = aligner.alignTranscript(
            fullText: "unused",
            tokenTimings: [token("▁hello", start: 0.0, end: 0.2)],
            diarizedSegments: [
                segment("S1", start: 0.0, end: 0.3),
                segment("S2", start: 0.8, end: 1.2)
            ],
            source: .mic
        )

        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].speakerId == "S1")
        #expect(transcript.speakers.count == 1)
    }

    @Test
    func alignWithGlobalOffsetTimingsAcrossMultipleChunks() {
        // Simulates two VAD chunks: chunk1 at 0-10s, chunk2 at 30-40s.
        // Token timings are already offset to global session time.
        let transcript = aligner.alignTranscript(
            fullText: "hello world foo bar",
            tokenTimings: [
                token("▁hello", start: 1.0, end: 1.4),  // chunk1 token, global time
                token("▁world", start: 2.0, end: 2.5),  // chunk1 token, global time
                token("▁foo",   start: 31.0, end: 31.5), // chunk2 token, global time
                token("▁bar",   start: 32.0, end: 32.5)  // chunk2 token, global time
            ],
            diarizedSegments: [
                segment("S1", start: 0.0, end: 15.0),
                segment("S2", start: 28.0, end: 40.0)
            ],
            source: .mic
        )

        #expect(transcript.segments.count == 2)
        #expect(transcript.segments[0].speakerId == "S1")
        #expect(transcript.segments[0].text == "hello world")
        #expect(transcript.segments[1].speakerId == "S2")
        #expect(transcript.segments[1].text == "foo bar")
    }

    @Test
    func alignInterleavedSpeakersInSingleChunk() {
        // Both Speaker A and B talk within the same 30s VAD chunk.
        // Diarizer identifies two distinct segments; aligner splits the ASR text.
        let transcript = aligner.alignTranscript(
            fullText: "hey there yes indeed",
            tokenTimings: [
                token("▁hey",    start: 0.5, end: 1.0),
                token("▁there",  start: 1.2, end: 1.8),
                token("▁yes",    start: 15.0, end: 15.4),
                token("▁indeed", start: 15.6, end: 16.2)
            ],
            diarizedSegments: [
                segment("S1", start: 0.0, end: 10.0),
                segment("S2", start: 10.0, end: 30.0)
            ],
            source: .mic
        )

        #expect(transcript.segments.count == 2)
        #expect(transcript.segments[0].speakerId == "S1")
        #expect(transcript.segments[0].text == "hey there")
        #expect(transcript.segments[1].speakerId == "S2")
        #expect(transcript.segments[1].text == "yes indeed")
    }

    @Test
    func speakerColorPaletteMethod() {
        #expect(aligner.speakerColorHex(at: 0) == "#4F46E5")
        #expect(aligner.speakerColorHex(at: 1) == "#16A34A")
        #expect(aligner.speakerColorHex(at: 6) == "#4F46E5")
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
