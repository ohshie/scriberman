import AVFoundation
import XCTest
@testable import Scriberman

final class AudioDownmixerTests: XCTestCase {
    func testToMonoStereoAveragesChannels() {
        let channelSamples: [[Float]] = [
            [0.4, 0.2, -0.4],
            [0.2, -0.2, 0.4]
        ]

        let mono = AudioDownmixer.toMono(channelSamples: channelSamples)

        XCTAssertEqual(mono.count, 3)
        XCTAssertEqual(mono[0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(mono[1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(mono[2], 0.0, accuracy: 0.0001)
    }

    func testToMonoSingleChannelPassthrough() {
        let samples: [Float] = [0.25, -0.5, 0.75]

        let mono = AudioDownmixer.toMono(channelSamples: [samples])

        XCTAssertEqual(mono, samples)
    }

    func testToMonoEmptyInputReturnsEmpty() {
        XCTAssertEqual(AudioDownmixer.toMono(channelSamples: []), [])
    }

    func testToMonoSkipsMismatchedChannelLength() {
        let channelSamples: [[Float]] = [
            [1.0, 2.0, 3.0],
            [10.0, 11.0]
        ]

        let mono = AudioDownmixer.toMono(channelSamples: channelSamples)

        XCTAssertEqual(mono.count, 3)
        XCTAssertEqual(mono[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(mono[1], 1.0, accuracy: 0.0001)
        XCTAssertEqual(mono[2], 1.5, accuracy: 0.0001)
    }

    func testToMonoBufferStereoAveragesChannels() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        channelData[0][0] = 0.4
        channelData[0][1] = 0.2
        channelData[0][2] = -0.4
        channelData[1][0] = 0.2
        channelData[1][1] = -0.2
        channelData[1][2] = 0.4

        let mono = AudioDownmixer.toMono(buffer: buffer)

        XCTAssertEqual(mono.count, 3)
        XCTAssertEqual(mono[0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(mono[1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(mono[2], 0.0, accuracy: 0.0001)
    }
}
