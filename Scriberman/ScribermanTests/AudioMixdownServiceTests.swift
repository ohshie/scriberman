import AVFoundation
import AudioToolbox
import Foundation
import XCTest
@testable import Scriberman

final class AudioMixdownServiceTests: XCTestCase {
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

    func testMixWithTwoSourcesAndZeroOffsetProducesStereoOutput() async throws {
        let service = AudioMixdownService(outputFormat: .linearPCMCaf)
        let micURL = tempDirectoryURL.appendingPathComponent("mic.wav")
        let appURL = tempDirectoryURL.appendingPathComponent("app.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("recording.caf")

        try writeMonoWAV(samples: Array(repeating: Float(0.25), count: 48_000), to: micURL)
        try writeMonoWAV(samples: Array(repeating: Float(-0.55), count: 48_000), to: appURL)
        try ensureReadableAudioFile(at: micURL)
        try ensureReadableAudioFile(at: appURL)

        do {
            try await service.mix(
                micURL: micURL,
                appURL: appURL,
                micStartHostTime: 1_000_000_000,
                appStartHostTime: 1_000_000_000,
                into: outputURL
            )
        } catch {
            if shouldSkipForSandboxAudioIO(error) {
                throw XCTSkip("Skipping mixdown test in sandboxed runtime: \(error.localizedDescription)")
            }
            throw error
        }

        let decoded = try decodePCM(from: outputURL)
        XCTAssertEqual(decoded.channelCount, 2)

        let leftAverage = mean(decoded.channelSamples[0].prefix(20_000))
        let rightAverage = mean(decoded.channelSamples[1].prefix(20_000))
        XCTAssertGreaterThan(leftAverage, 0.10)
        XCTAssertLessThan(rightAverage, -0.20)
        XCTAssertGreaterThan(abs(leftAverage - rightAverage), 0.25)
    }

    func testMixWithNilAppProducesMonoOutput() async throws {
        let service = AudioMixdownService(outputFormat: .linearPCMCaf)
        let micURL = tempDirectoryURL.appendingPathComponent("mic.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("recording.caf")

        try writeMonoWAV(samples: Array(repeating: Float(0.3), count: 24_000), to: micURL)
        try ensureReadableAudioFile(at: micURL)

        do {
            try await service.mix(
                micURL: micURL,
                appURL: nil,
                micStartHostTime: 2_000_000_000,
                appStartHostTime: nil,
                into: outputURL
            )
        } catch {
            if shouldSkipForSandboxAudioIO(error) {
                throw XCTSkip("Skipping mixdown test in sandboxed runtime: \(error.localizedDescription)")
            }
            throw error
        }

        let decoded = try decodePCM(from: outputURL)
        XCTAssertEqual(decoded.channelCount, 1)
        let average = mean(decoded.channelSamples[0].prefix(10_000))
        XCTAssertGreaterThan(average, 0.15)
    }

    func testMixWithHalfSecondAppOffsetPadsRightChannelSilence() async throws {
        let service = AudioMixdownService(outputFormat: .linearPCMCaf)
        let micURL = tempDirectoryURL.appendingPathComponent("mic.wav")
        let appURL = tempDirectoryURL.appendingPathComponent("app.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("recording.caf")

        try writeMonoWAV(samples: Array(repeating: Float(0.1), count: 60_000), to: micURL)
        try writeMonoWAV(samples: Array(repeating: Float(0.8), count: 24_000), to: appURL)
        try ensureReadableAudioFile(at: micURL)
        try ensureReadableAudioFile(at: appURL)

        do {
            try await service.mix(
                micURL: micURL,
                appURL: appURL,
                micStartHostTime: 1_000_000_000,
                appStartHostTime: 1_500_000_000,
                into: outputURL
            )
        } catch {
            if shouldSkipForSandboxAudioIO(error) {
                throw XCTSkip("Skipping mixdown test in sandboxed runtime: \(error.localizedDescription)")
            }
            throw error
        }

        let decoded = try decodePCM(from: outputURL)
        XCTAssertEqual(decoded.channelCount, 2)

        let right = decoded.channelSamples[1]
        XCTAssertGreaterThan(right.count, 26_000)
        let preOffsetAverage = meanAbsolute(right.prefix(23_000))
        XCTAssertLessThan(preOffsetAverage, 0.05)
        XCTAssertGreaterThan(abs(right[24_000]), 0.3)
    }

    func testMixDefaultFormatProducesAACM4AAt48kHz() async throws {
        let service = AudioMixdownService()
        let micURL = tempDirectoryURL.appendingPathComponent("mic.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("recording.m4a")

        try writeMonoWAV(samples: Array(repeating: Float(0.2), count: 24_000), to: micURL)
        try ensureReadableAudioFile(at: micURL)

        try await service.mix(
            micURL: micURL,
            appURL: nil,
            micStartHostTime: 1_000_000_000,
            appStartHostTime: nil,
            into: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let asbd = try readAudioStreamDescription(from: outputURL)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(asbd.mChannelsPerFrame, 1)
        XCTAssertEqual(asbd.mSampleRate, 48_000, accuracy: 1.0)
    }

    func testMixDeletesSourceWAVFilesAfterSuccessfulWrite() async throws {
        let service = AudioMixdownService(outputFormat: .linearPCMCaf)
        let micURL = tempDirectoryURL.appendingPathComponent("mic.wav")
        let appURL = tempDirectoryURL.appendingPathComponent("app.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("recording.caf")

        try writeMonoWAV(samples: Array(repeating: Float(0.15), count: 48_000), to: micURL)
        try writeMonoWAV(samples: Array(repeating: Float(0.45), count: 48_000), to: appURL)
        try ensureReadableAudioFile(at: micURL)
        try ensureReadableAudioFile(at: appURL)

        do {
            try await service.mix(
                micURL: micURL,
                appURL: appURL,
                micStartHostTime: 1_000_000_000,
                appStartHostTime: 1_000_000_000,
                into: outputURL
            )
        } catch {
            if shouldSkipForSandboxAudioIO(error) {
                throw XCTSkip("Skipping mixdown deletion test in sandboxed runtime: \(error.localizedDescription)")
            }
            throw error
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: appURL.path))
    }

    func testDeletionFailureDoesNotFailMixOrOutput() async throws {
        let failingURL = tempDirectoryURL.appendingPathComponent("app.wav")
        let service = AudioMixdownService(
            outputFormat: .linearPCMCaf,
            removeItemAtURL: { url in
                if url.path == failingURL.path {
                    throw RecordingError.failedToStart("Forced deletion failure")
                }
                try FileManager.default.removeItem(at: url)
            }
        )

        let micURL = tempDirectoryURL.appendingPathComponent("mic.wav")
        let appURL = failingURL
        let outputURL = tempDirectoryURL.appendingPathComponent("recording.caf")

        try writeMonoWAV(samples: Array(repeating: Float(0.2), count: 48_000), to: micURL)
        try writeMonoWAV(samples: Array(repeating: Float(0.3), count: 48_000), to: appURL)
        try ensureReadableAudioFile(at: micURL)
        try ensureReadableAudioFile(at: appURL)

        do {
            try await service.mix(
                micURL: micURL,
                appURL: appURL,
                micStartHostTime: 1_000_000_000,
                appStartHostTime: 1_000_000_000,
                into: outputURL
            )
        } catch {
            if shouldSkipForSandboxAudioIO(error) {
                throw XCTSkip("Skipping mixdown deletion-failure test in sandboxed runtime: \(error.localizedDescription)")
            }
            throw error
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
    }

    private struct DecodedPCM {
        let channelCount: Int
        let channelSamples: [[Float]]
    }

    private func writeMonoWAV(samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else {
            XCTFail("Failed to build mono WAV format")
            return
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
                throw RecordingError.failedToStart("Failed to allocate WAV write buffer for tests.")
            }

            buffer.frameLength = AVAudioFrameCount(frameCount)
            for sampleIndex in 0..<frameCount {
                let sample = samples[index + sampleIndex]
                let clamped = max(-1.0, min(1.0, sample))
                channelData[0][sampleIndex] = Int16(clamped * Float(Int16.max))
            }
            try file.write(from: buffer)
            index += frameCount
        }
    }

    private func decodePCM(from url: URL) throws -> DecodedPCM {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ), let channelData = buffer.floatChannelData else {
            throw RecordingError.failedToStart("Failed to decode mixed output for tests.")
        }

        try file.read(into: buffer)
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)

        let channelSamples = (0..<channelCount).map { channelIndex in
            Array(UnsafeBufferPointer(start: channelData[channelIndex], count: frameCount))
        }
        return DecodedPCM(channelCount: channelCount, channelSamples: channelSamples)
    }

    private func mean<S: Sequence>(_ sequence: S) -> Float where S.Element == Float {
        var total: Float = 0
        var count: Int = 0
        for value in sequence {
            total += value
            count += 1
        }
        guard count > 0 else { return 0 }
        return total / Float(count)
    }

    private func meanAbsolute<S: Sequence>(_ sequence: S) -> Float where S.Element == Float {
        var total: Float = 0
        var count: Int = 0
        for value in sequence {
            total += abs(value)
            count += 1
        }
        guard count > 0 else { return 0 }
        return total / Float(count)
    }

    private func ensureReadableAudioFile(at url: URL) throws {
        do {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: 1
            ) else {
                throw RecordingError.failedToStart("Probe buffer allocation failed.")
            }
            try file.read(into: buffer, frameCount: 1)
        } catch {
            if shouldSkipForSandboxAudioIO(error) {
                throw XCTSkip("Skipping mixdown tests: AVAudioFile read unavailable in sandbox (\(error.localizedDescription))")
            }
            throw error
        }
    }

    private func shouldSkipForSandboxAudioIO(_ error: Error) -> Bool {
        let message = String(describing: error)
        return message.contains("Foundation._GenericObjCError")
            || message.contains("nilError")
    }

    private func readAudioStreamDescription(from url: URL) throws -> AudioStreamBasicDescription {
        var fileID: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID)
        guard openStatus == noErr, let fileID else {
            throw RecordingError.failedToStart("AudioFileOpenURL failed: \(openStatus)")
        }
        defer { AudioFileClose(fileID) }

        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioFileGetProperty(fileID, kAudioFilePropertyDataFormat, &dataSize, &asbd)
        guard formatStatus == noErr else {
            throw RecordingError.failedToStart("AudioFileGetProperty(dataFormat) failed: \(formatStatus)")
        }
        return asbd
    }
}
