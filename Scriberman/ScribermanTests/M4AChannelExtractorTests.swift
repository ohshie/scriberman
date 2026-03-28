import AVFoundation
import Foundation
import XCTest
@testable import Scriberman

final class M4AChannelExtractorTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        try super.tearDownWithError()
    }

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
                throw XCTSkip("Skipping stereo extraction in sandboxed runtime: \(error.localizedDescription)")
            }
            throw error
        }

        let extracted = try extractor.extract(url: url, isStereo: true)

        XCTAssertNotNil(extracted.app)
        XCTAssertEqual(extracted.mic.count, 16_000)
        XCTAssertEqual(extracted.app?.count, 16_000)
        XCTAssertGreaterThan(mean(extracted.mic.prefix(8_000)), 0.1)
        XCTAssertLessThan(mean((extracted.app ?? []).prefix(8_000)), -0.2)
    }

    func testExtractMonoReturnsMicOnly() throws {
        let extractor = M4AChannelExtractor()
        let url = tempDirectoryURL.appendingPathComponent("mono.m4a")
        let halfSecond48k = 24_000
        let mic = Array(repeating: Float(0.4), count: halfSecond48k)

        do {
            try writeM4A(channels: [mic], sampleRate: 48_000, to: url)
        } catch {
            if shouldSkipForSandboxAudioIO(error) {
                throw XCTSkip("Skipping mono extraction in sandboxed runtime: \(error.localizedDescription)")
            }
            throw error
        }

        let extracted = try extractor.extract(url: url, isStereo: false)

        XCTAssertNil(extracted.app)
        XCTAssertEqual(extracted.mic.count, 8_000)
        XCTAssertGreaterThan(mean(extracted.mic.prefix(4_000)), 0.2)
    }

    func testExtractMissingFileThrowsDescriptiveError() {
        let extractor = M4AChannelExtractor()
        let missingURL = tempDirectoryURL.appendingPathComponent("missing.m4a")

        XCTAssertThrowsError(try extractor.extract(url: missingURL, isStereo: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Audio file not found"))
        }
    }

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
                throw XCTSkip("Skipping sample-rate extraction in sandboxed runtime: \(error.localizedDescription)")
            }
            throw error
        }

        let extracted = try extractor.extract(url: url, isStereo: false)
        XCTAssertEqual(extracted.mic.count, 16_000 * durationSeconds)
    }

    private func writeM4A(channels: [[Float]], sampleRate: Double, to url: URL) throws {
        guard !channels.isEmpty else {
            XCTFail("Expected at least one channel.")
            return
        }
        let frameCount = channels[0].count
        guard channels.allSatisfy({ $0.count == frameCount }) else {
            XCTFail("All channels must have equal frame count.")
            return
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
                    channelData[channelIndex].assign(from: baseAddress, count: frames)
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
