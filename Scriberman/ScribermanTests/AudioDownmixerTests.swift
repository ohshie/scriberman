import AVFoundation
import Testing
@testable import Scriberman

final class AudioDownmixerTests {
    @Test
    func testToMonoStereoAveragesChannels() {
        let channelSamples: [[Float]] = [
            [0.4, 0.2, -0.4],
            [0.2, -0.2, 0.4]
        ]

        let mono = AudioDownmixer.toMono(channelSamples: channelSamples)

        #expect(mono.count == 3)
        #expect(abs(mono[0] - 0.3) < 0.0001)
        #expect(abs(mono[1] - 0.0) < 0.0001)
        #expect(abs(mono[2] - 0.0) < 0.0001)
    }

    @Test
    func testToMonoSingleChannelPassthrough() {
        let samples: [Float] = [0.25, -0.5, 0.75]

        let mono = AudioDownmixer.toMono(channelSamples: [samples])

        #expect(mono == samples)
    }

    @Test
    func testToMonoEmptyInputReturnsEmpty() {
        #expect(AudioDownmixer.toMono(channelSamples: []) == [])
    }

    @Test
    func testToMonoSkipsMismatchedChannelLength() {
        let channelSamples: [[Float]] = [
            [1.0, 2.0, 3.0],
            [10.0, 11.0]
        ]

        let mono = AudioDownmixer.toMono(channelSamples: channelSamples)

        #expect(mono.count == 3)
        #expect(abs(mono[0] - 0.5) < 0.0001)
        #expect(abs(mono[1] - 1.0) < 0.0001)
        #expect(abs(mono[2] - 1.5) < 0.0001)
    }

    @Test
    func testToMonoBufferStereoAveragesChannels() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 2,
                interleaved: false
            )
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let channelData = try #require(buffer.floatChannelData)
        channelData[0][0] = 0.4
        channelData[0][1] = 0.2
        channelData[0][2] = -0.4
        channelData[1][0] = 0.2
        channelData[1][1] = -0.2
        channelData[1][2] = 0.4

        let mono = AudioDownmixer.toMono(buffer: buffer)

        #expect(mono.count == 3)
        #expect(abs(mono[0] - 0.3) < 0.0001)
        #expect(abs(mono[1] - 0.0) < 0.0001)
        #expect(abs(mono[2] - 0.0) < 0.0001)
    }
}
