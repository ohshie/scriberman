import AVFoundation
import Foundation
import Testing
@testable import Scriberman

final class AudioFileProberTests {
    private let tempDirectoryURL: URL

    init() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
    }

    @Test
    func testProbeReturnsFileMetadataAndDuration() async throws {
        let url = tempDirectoryURL.appendingPathComponent("team-sync.wav")
        try writeMonoWAV(samples: Array(repeating: Float(0.25), count: 24_000), to: url)

        let prober = AudioFileProber()
        let result = try await prober.probe(url: url)

        #expect(result.title == "team-sync")
        #expect(result.originalFileName == "team-sync.wav")
        #expect(result.originalFormat == "wav")
        #expect(result.duration > 0.45)
    }

    private func writeMonoWAV(samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.failedToStart("Failed to create test mono format.")
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        var index = 0
        while index < samples.count {
            let frameCount = min(4_096, samples.count - index)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let channelData = buffer.int16ChannelData else {
                throw RecordingError.failedToStart("Failed to allocate test mono buffer.")
            }

            buffer.frameLength = AVAudioFrameCount(frameCount)
            for sampleIndex in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, samples[index + sampleIndex]))
                channelData[0][sampleIndex] = Int16(clamped * Float(Int16.max))
            }
            try file.write(from: buffer)
            index += frameCount
        }
    }
}
