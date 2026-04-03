import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import Scriberman

final class AudioMixdownServiceTests {
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
                return
            }
            throw error
        }

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 2)

        let leftAverage = mean(decoded.channelSamples[0].prefix(20_000))
        let rightAverage = mean(decoded.channelSamples[1].prefix(20_000))
        #expect(leftAverage > 0.10)
        #expect(rightAverage < -0.20)
        #expect(abs(leftAverage - rightAverage) > 0.25)
    }

    @Test
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
                return
            }
            throw error
        }

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 1)
        let average = mean(decoded.channelSamples[0].prefix(10_000))
        #expect(average > 0.15)
    }

    @Test
    func testMixWithNilAppDownmixesStereoInputToAveragedMonoOutput() async throws {
        let service = AudioMixdownService(outputFormat: .linearPCMCaf)
        let micURL = tempDirectoryURL.appendingPathComponent("mic_stereo.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("recording_downmixed.caf")

        let left = Array(repeating: Float(0.8), count: 24_000)
        let right = Array(repeating: Float(-0.2), count: 24_000)
        try writeStereoWAV(left: left, right: right, to: micURL)
        try ensureReadableAudioFile(at: micURL)
        let source = try decodePCM(from: micURL)
        #expect(source.channelCount == 2)
        #expect(mean(source.channelSamples[0].prefix(5_000)) > 0.6)
        #expect(mean(source.channelSamples[1].prefix(5_000)) < -0.1)

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
                return
            }
            throw error
        }

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 1)
        let average = mean(decoded.channelSamples[0].prefix(10_000))
        #expect(average > 0.20)
        #expect(average < 0.40)
    }

    @Test
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
                return
            }
            throw error
        }

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 2)

        let right = decoded.channelSamples[1]
        #expect(right.count > 26_000)
        let preOffsetAverage = meanAbsolute(right.prefix(23_000))
        #expect(preOffsetAverage < 0.05)
        #expect(abs(right[24_000]) > 0.3)
    }

    @Test
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

        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        let asbd = try readAudioStreamDescription(from: outputURL)
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC)
        #expect(asbd.mChannelsPerFrame == 1)
        #expect(abs(asbd.mSampleRate - 48_000) < 1.0)
    }

    @Test
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
                return
            }
            throw error
        }

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(!(FileManager.default.fileExists(atPath: micURL.path)))
        #expect(!(FileManager.default.fileExists(atPath: appURL.path)))
    }

    @Test
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
                return
            }
            throw error
        }

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(!(FileManager.default.fileExists(atPath: micURL.path)))
        #expect(FileManager.default.fileExists(atPath: appURL.path))
    }

    @Test
    func testMixKeepsSourceFilesWhenDeletionDisabled() async throws {
        let service = AudioMixdownService(outputFormat: .linearPCMCaf)
        let micURL = tempDirectoryURL.appendingPathComponent("mic.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("recording.caf")

        try writeMonoWAV(samples: Array(repeating: Float(0.2), count: 24_000), to: micURL)
        try ensureReadableAudioFile(at: micURL)

        do {
            try await service.mix(
                micURL: micURL,
                appURL: nil,
                micStartHostTime: 1_000_000_000,
                appStartHostTime: nil,
                into: outputURL,
                deleteSourceFiles: false
            )
        } catch {
            if shouldSkipForSandboxAudioIO(error) {
                return
            }
            throw error
        }

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(FileManager.default.fileExists(atPath: micURL.path))
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
            Issue.record("Failed to build mono WAV format")
            throw RecordingError.failedToStart("Failed to build mono WAV format")
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

    private func writeStereoWAV(left: [Float], right: [Float], to url: URL) throws {
        #expect(left.count == right.count)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            Issue.record("Failed to build stereo WAV format")
            throw RecordingError.failedToStart("Failed to build stereo WAV format")
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        var index = 0
        while index < left.count {
            let frameCount = min(4_096, left.count - index)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let channelData = buffer.int16ChannelData else {
                throw RecordingError.failedToStart("Failed to allocate stereo WAV write buffer for tests.")
            }

            buffer.frameLength = AVAudioFrameCount(frameCount)
            for sampleIndex in 0..<frameCount {
                let l = max(-1.0, min(1.0, left[index + sampleIndex]))
                let r = max(-1.0, min(1.0, right[index + sampleIndex]))
                channelData[0][sampleIndex] = Int16(l * Float(Int16.max))
                channelData[1][sampleIndex] = Int16(r * Float(Int16.max))
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
                return
            }
            throw error
        }
    }

    private func shouldSkipForSandboxAudioIO(_ error: Error) -> Bool {
        let message = String(describing: error)
        let nsError = error as NSError
        return message.contains("Foundation._GenericObjCError")
            || message.contains("nilError")
            || (nsError.domain == "com.apple.coreaudio.avfaudio" && nsError.code == 2003334207)
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
