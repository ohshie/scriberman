import Foundation
import Testing
@testable import Scriberman

struct SpeakerVoiceprintExtractorTests {
    private typealias Range = SpeakerVoiceprintExtractor.SpeakerRange

    /// One embed call: the window's sample count and its masks.
    private struct Call {
        let sampleCount: Int
        let masks: [[Float]]
    }

    private final class Recorder: @unchecked Sendable {
        var calls: [Call] = []
    }

    /// An extractor whose fake model returns, per mask, a unit vector chosen by `embedding`.
    private static func extractor(
        frameCount: Int = 100,
        recorder: Recorder = Recorder(),
        embedding: @escaping (Int) -> [Float] = { _ in [1, 0, 0] }
    ) -> SpeakerVoiceprintExtractor {
        SpeakerVoiceprintExtractor(maskFrameCount: frameCount) { window, masks in
            recorder.calls.append(Call(sampleCount: window.count, masks: masks))
            return masks.indices.map(embedding)
        }
    }

    private static func samples(seconds: Double) -> [Float] {
        Array(repeating: 0.1, count: Int(seconds * 16_000))
    }

    // MARK: - Runs

    @Test
    func overlapWithAnotherSpeakerIsExcluded() {
        let runs = SpeakerVoiceprintExtractor.exclusiveRuns([
            Range(speaker: "S1", start: 0, end: 12),
            Range(speaker: "S2", start: 10, end: 20)
        ])
        #expect(runs["S1"] == [0...10])
        #expect(runs["S2"] == [12...20])
    }

    @Test
    func runsShorterThanOneSecondAreDropped() {
        let runs = SpeakerVoiceprintExtractor.exclusiveRuns([
            Range(speaker: "S1", start: 0, end: 0.9),
            Range(speaker: "S1", start: 5, end: 6.5),
            Range(speaker: "S2", start: 3, end: 3.5)
        ])
        #expect(runs["S1"] == [5...6.5])
        #expect(runs["S2"] == nil)
    }

    @Test
    func adjacentRunsOfOneSpeakerMerge() {
        let runs = SpeakerVoiceprintExtractor.exclusiveRuns([
            Range(speaker: "S1", start: 0, end: 0.6),
            Range(speaker: "S1", start: 0.6, end: 1.2)
        ])
        #expect(runs["S1"] == [0...1.2])
    }

    // MARK: - Windows and masks

    @Test
    func masksFollowWindowBoundaries() throws {
        let recorder = Recorder()
        let extractor = Self.extractor(frameCount: 100, recorder: recorder)

        _ = try extractor.voiceprints(
            samples: Self.samples(seconds: 15),
            ranges: [Range(speaker: "S1", start: 8, end: 13)]
        )

        #expect(recorder.calls.count == 2)
        #expect(recorder.calls[0].sampleCount == 160_000)
        #expect(recorder.calls[1].sampleCount == 80_000)
        // 100 frames per 10 s: frames 80…99 cover 8–10 s of the first window.
        let first = try #require(recorder.calls[0].masks.first)
        #expect(first[79] == 0)
        #expect(first[80] == 1)
        #expect(first[99] == 1)
        // The second window starts at 10 s: frames 0…29 cover 10–13 s.
        let second = try #require(recorder.calls[1].masks.first)
        #expect(second[29] == 1)
        #expect(second[30] == 0)
    }

    @Test
    func windowWithoutSpeechIsNotEmbedded() throws {
        let recorder = Recorder()
        _ = try Self.extractor(recorder: recorder).voiceprints(
            samples: Self.samples(seconds: 25),
            ranges: [Range(speaker: "S1", start: 21, end: 25)]
        )
        #expect(recorder.calls.count == 1)
    }

    // MARK: - Voiceprints

    @Test
    func speakerBelowThreeSecondsGetsNoVoiceprint() throws {
        let result = try Self.extractor().voiceprints(
            samples: Self.samples(seconds: 10),
            ranges: [Range(speaker: "S1", start: 0, end: 2.5), Range(speaker: "S2", start: 3, end: 7)]
        )
        #expect(result["S1"] == nil)
        #expect(result["S2"]?.speechSeconds == 4)
    }

    @Test
    func voiceprintIsDurationWeightedAndNormalised() throws {
        // Window 1 holds 8 s of S1 and yields (1, 0); window 2 holds 2 s and yields (0, 1).
        var call = 0
        let extractor = SpeakerVoiceprintExtractor(maskFrameCount: 100) { _, masks in
            call += 1
            return masks.map { _ in call == 1 ? [1, 0] : [0, 1] }
        }

        let result = try extractor.voiceprints(
            samples: Self.samples(seconds: 20),
            ranges: [Range(speaker: "S1", start: 2, end: 12)]
        )

        let voiceprint = try #require(result["S1"])
        #expect(voiceprint.speechSeconds == 10)
        let norm = (64.0 + 4.0).squareRoot()
        #expect(abs(Double(voiceprint.embedding[0]) - 8 / norm) < 1e-5)
        #expect(abs(Double(voiceprint.embedding[1]) - 2 / norm) < 1e-5)
    }

    @Test
    func zeroEmbeddingIsIgnored() throws {
        let extractor = Self.extractor(embedding: { _ in [0, 0, 0] })
        let result = try extractor.voiceprints(
            samples: Self.samples(seconds: 10),
            ranges: [Range(speaker: "S1", start: 0, end: 8)]
        )
        #expect(result.isEmpty)
    }
}
