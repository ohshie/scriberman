import AVFoundation
import Foundation
import Testing
@testable import Scriberman

final class M4AChannelExtractorTests {
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
    func testExtractStereoReturnsMicAndAppSamples() throws {
        let extractor = M4AChannelExtractor()
        let url = tempDirectoryURL.appendingPathComponent("stereo.m4a")
        let oneSecond48k = 48_000
        let mic = Array(repeating: Float(0.25), count: oneSecond48k)
        let app = Array(repeating: Float(-0.5), count: oneSecond48k)

        do {
            try writeM4A(channels: [mic, app], sampleRate: 48_000, to: url)
        } catch {
            if shouldSkipForSandboxAudioIO(error) {
                return
            }
            throw error
        }

        let extracted = try extractor.extract(url: url, isStereo: true)

        #expect(extracted.app != nil)
        #expect(extracted.mic.count == 16_000)
        #expect(extracted.app?.count == 16_000)
        #expect(mean(extracted.mic.prefix(8_000)) > 0.1)
        #expect(mean((extracted.app ?? []).prefix(8_000)) < -0.2)
    }

    @Test
    func testExtractMonoReturnsMicOnly() throws {
        let extractor = M4AChannelExtractor()
        let url = tempDirectoryURL.appendingPathComponent("mono.m4a")
        let halfSecond48k = 24_000
        let mic = Array(repeating: Float(0.4), count: halfSecond48k)

        do {
            try writeM4A(channels: [mic], sampleRate: 48_000, to: url)
        } catch {
            if shouldSkipForSandboxAudioIO(error) {
                return
            }
            throw error
        }

        let extracted = try extractor.extract(url: url, isStereo: false)

        #expect(extracted.app == nil)
        #expect(extracted.mic.count == 8_000)
        #expect(mean(extracted.mic.prefix(4_000)) > 0.2)
    }

    @Test
    func testExtractMissingFileThrowsDescriptiveError() {
        let extractor = M4AChannelExtractor()
        let missingURL = tempDirectoryURL.appendingPathComponent("missing.m4a")

        do {
            _ = try extractor.extract(url: missingURL, isStereo: false)
            Issue.record("Expected extraction to throw for missing input file")
            return
        } catch {
            #expect(error.localizedDescription.contains("Audio file not found"))
        }
    }

    @Test
    func testExtractResamplesTo16kHzByOutputLength() throws {
        let extractor = M4AChannelExtractor()
        let url = tempDirectoryURL.appendingPathComponent("duration-check.m4a")
        let durationSeconds = 2
        let inputSampleCount = 48_000 * durationSeconds
        let mic = Array(repeating: Float(0.2), count: inputSampleCount)

        do {
            try writeM4A(channels: [mic], sampleRate: 48_000, to: url)
        } catch {
            if shouldSkipForSandboxAudioIO(error) {
                return
            }
            throw error
        }

        let extracted = try extractor.extract(url: url, isStereo: false)
        #expect(extracted.mic.count == 16_000 * durationSeconds)
    }

    private func writeM4A(channels: [[Float]], sampleRate: Double, to url: URL) throws {
        guard !channels.isEmpty else {
            Issue.record("Expected at least one channel.")
            throw RecordingError.failedToStart("Expected at least one channel.")
        }
        let frameCount = channels[0].count
        guard channels.allSatisfy({ $0.count == frameCount }) else {
            Issue.record("All channels must have equal frame count.")
            throw RecordingError.failedToStart("All channels must have equal frame count.")
        }

        let channelCount = channels.count
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let outputFile = try AVAudioFile(forWriting: url, settings: settings)
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw RecordingError.failedToStart("Failed to create input format for m4a test writer.")
        }

        var index = 0
        let chunkSize = 4_096
        while index < frameCount {
            let remaining = frameCount - index
            let frames = min(remaining, chunkSize)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(frames)
            ), let channelData = buffer.floatChannelData else {
                throw RecordingError.failedToStart("Failed to allocate test m4a buffer.")
            }
            buffer.frameLength = AVAudioFrameCount(frames)

            for channelIndex in 0..<channelCount {
                channels[channelIndex][index..<(index + frames)].withUnsafeBufferPointer { pointer in
                    guard let baseAddress = pointer.baseAddress else { return }
                    channelData[channelIndex].update(from: baseAddress, count: frames)
                }
            }

            try outputFile.write(from: buffer)
            index += frames
        }
    }

    private func mean<S: Sequence>(_ sequence: S) -> Float where S.Element == Float {
        var total: Float = 0
        var count = 0
        for value in sequence {
            total += value
            count += 1
        }
        guard count > 0 else { return 0 }
        return total / Float(count)
    }

    private func shouldSkipForSandboxAudioIO(_ error: Error) -> Bool {
        let message = String(describing: error)
        return message.contains("Foundation._GenericObjCError")
            || message.contains("nilError")
    }
}
