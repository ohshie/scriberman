import Foundation
import Testing
@testable import Scriberman

final class AudioResamplerTests {
    @Test
    func testResampleSameRateReturnsInputUnchanged() throws {
        let samples = makeSineSamples(sampleRate: 48_000, frequency: 440, durationSeconds: 1.0)
        let resampler = AudioResampler(targetSampleRate: 48_000)

        let output = try resampler.resample(samples, from: 48_000)

        #expect(output.count == samples.count)
        for index in 0..<samples.count {
            #expect(abs(output[index] - samples[index]) < 0.000001)
        }
    }

    @Test
    func testResampleDownsample48kTo16k() throws {
        let samples = makeSineSamples(sampleRate: 48_000, frequency: 440, durationSeconds: 1.0)
        let resampler = AudioResampler(targetSampleRate: 16_000)

        let output = try resampler.resample(samples, from: 48_000)

        #expect(output.count == 16_000)
    }

    @Test
    func testResampleUpsample16kTo48k() throws {
        let samples = makeSineSamples(sampleRate: 16_000, frequency: 440, durationSeconds: 1.0)
        let resampler = AudioResampler(targetSampleRate: 48_000)

        let output = try resampler.resample(samples, from: 16_000)

        #expect(output.count == 48_000)
    }

    @Test
    func testResampleEmptyInputReturnsEmpty() throws {
        let resampler = AudioResampler(targetSampleRate: 16_000)

        let output = try resampler.resample([], from: 48_000)

        #expect(output.isEmpty)
    }

    private func makeSineSamples(sampleRate: Double, frequency: Double, durationSeconds: Double) -> [Float] {
        let sampleCount = Int(sampleRate * durationSeconds)
        return (0..<sampleCount).map { index in
            let time = Double(index) / sampleRate
            return Float(sin(2.0 * .pi * frequency * time))
        }
    }
}

struct ContinuousAudioResamplerTests {
    @Test
    func sixtySecondsPreservesFractionalSamplesAcrossCallbacks() throws {
        let resampler = try ContinuousAudioResampler(sourceSampleRate: 48_000)
        var count = 0
        let inputCount = 60 * 48_000
        for offset in stride(from: 0, to: inputCount, by: 1_024) {
            count += try resampler.convert(Array(repeating: 0.1, count: min(1_024, inputCount - offset))).count
        }
        count += try resampler.finish().count
        #expect(abs(count - 960_000) <= 4_096)
        #expect(try resampler.finish().isEmpty)
    }

    @Test
    func stopRestartPreservesOrderAndRejectsOldToken() async throws {
        let first = DictationAudioPipeline(converter: PassthroughDictationConverter())
        for index in 0..<100 { first.append([Float(index)], generation: first.generation) }
        await first.stop()
        let second = DictationAudioPipeline(converter: PassthroughDictationConverter())
        second.append([999], generation: first.generation)
        first.append([999], generation: first.generation)
        second.append([100], generation: second.generation)
        await second.stop()
        var firstSamples: [Float] = []
        for try await samples in first.stream { firstSamples += samples }
        var secondSamples: [Float] = []
        for try await samples in second.stream { secondSamples += samples }
        #expect(firstSamples == (0..<100).map(Float.init))
        #expect(secondSamples == [100])
    }
}

private struct PassthroughDictationConverter: DictationAudioConverting {
    func convert(_ samples: [Float]) throws -> [Float] { samples }
    func finish() throws -> [Float] { [] }
}
