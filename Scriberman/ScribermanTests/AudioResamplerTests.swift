import Foundation
import XCTest
@testable import Scriberman

final class AudioResamplerTests: XCTestCase {
    func testResampleSameRateReturnsInputUnchanged() throws {
        let samples = makeSineSamples(sampleRate: 48_000, frequency: 440, durationSeconds: 1.0)
        let resampler = AudioResampler(targetSampleRate: 48_000)

        let output = try resampler.resample(samples, from: 48_000)

        XCTAssertEqual(output.count, samples.count)
        for index in 0..<samples.count {
            XCTAssertEqual(output[index], samples[index], accuracy: 0.000001)
        }
    }

    func testResampleDownsample48kTo16k() throws {
        let samples = makeSineSamples(sampleRate: 48_000, frequency: 440, durationSeconds: 1.0)
        let resampler = AudioResampler(targetSampleRate: 16_000)

        let output = try resampler.resample(samples, from: 48_000)

        XCTAssertEqual(output.count, 16_000)
    }

    func testResampleUpsample16kTo48k() throws {
        let samples = makeSineSamples(sampleRate: 16_000, frequency: 440, durationSeconds: 1.0)
        let resampler = AudioResampler(targetSampleRate: 48_000)

        let output = try resampler.resample(samples, from: 16_000)

        XCTAssertEqual(output.count, 48_000)
    }

    func testResampleEmptyInputReturnsEmpty() throws {
        let resampler = AudioResampler(targetSampleRate: 16_000)

        let output = try resampler.resample([], from: 48_000)

        XCTAssertTrue(output.isEmpty)
    }

    private func makeSineSamples(sampleRate: Double, frequency: Double, durationSeconds: Double) -> [Float] {
        let sampleCount = Int(sampleRate * durationSeconds)
        return (0..<sampleCount).map { index in
            let time = Double(index) / sampleRate
            return Float(sin(2.0 * .pi * frequency * time))
        }
    }
}
