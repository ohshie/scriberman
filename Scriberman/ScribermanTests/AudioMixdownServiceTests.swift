import AVFoundation
import AudioToolbox
import Foundation
import SwiftData
import Testing
@testable import Scriberman

@Suite(.enabled(if: AudioIOAvailability.isAvailable, AudioIOAvailability.unavailableReason))
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

    // MARK: - Timeline path preconditions

    /// Writes a `.timing` sidecar describing `segmentCount` contiguous 960-frame segments.
    private func writeSidecar(for audioURL: URL, segmentCount: Int, framesPerSegment: Int = 960) throws {
        let segments = (0..<segmentCount).map { index in
            AudioCaptureSegment(
                startHostTimeNanos: UInt64(index) * 20_000_000 + 1_000_000_000,
                frameCount: framesPerSegment
            )
        }
        let sidecar = CaptureTimingSidecar(sampleRate: 48_000, segments: segments)
        let data = try JSONEncoder().encode(sidecar)
        try data.write(to: AudioFileStreamer.timingSidecarURL(for: audioURL), options: .atomic)
    }

    /// A recording whose sidecar agrees with its file mixes on the presentation-timestamp path.
    /// After the capture-time invariant, agreement is the normal case rather than the lucky one.
    @Test
    func testAgreeingSidecarProducesStereoOutput() async throws {
        let service = AudioMixdownService(outputFormat: .linearPCMCaf)
        let micURL = tempDirectoryURL.appendingPathComponent("mic-agree.wav")
        let appURL = tempDirectoryURL.appendingPathComponent("app-agree.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("agree.caf")

        try writeMonoWAV(samples: Array(repeating: Float(0.25), count: 48_000), to: micURL)
        try writeMonoWAV(samples: Array(repeating: Float(-0.55), count: 48_000), to: appURL)
        try ensureReadableAudioFile(at: micURL)
        try ensureReadableAudioFile(at: appURL)
        try writeSidecar(for: micURL, segmentCount: 50)
        try writeSidecar(for: appURL, segmentCount: 50)

        try await service.mix(
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            into: outputURL
        )

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 2)
    }

    /// A sidecar that genuinely disagrees with its file must still be refused, and the recording
    /// must still be mixed by the fallback rather than failing. The guard is now an assertion on
    /// the capture-time invariant, so it should never fire in practice — but it must keep working.
    @Test
    func testDisagreeingSidecarIsRefusedAndStillProducesOutput() async throws {
        let service = AudioMixdownService(outputFormat: .linearPCMCaf)
        let micURL = tempDirectoryURL.appendingPathComponent("mic-disagree.wav")
        let appURL = tempDirectoryURL.appendingPathComponent("app-disagree.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("disagree.caf")

        try writeMonoWAV(samples: Array(repeating: Float(0.25), count: 48_000), to: micURL)
        try writeMonoWAV(samples: Array(repeating: Float(-0.55), count: 48_000), to: appURL)
        try ensureReadableAudioFile(at: micURL)
        try ensureReadableAudioFile(at: appURL)
        // Claims 60 segments (57_600 frames) for a 48_000-frame file.
        try writeSidecar(for: micURL, segmentCount: 60)
        try writeSidecar(for: appURL, segmentCount: 60)

        try await service.mix(
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            into: outputURL
        )

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 2)
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

        try await service.mix(
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            into: outputURL
        )

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 2)
        #expect(decoded.sampleRate == 48_000)
        #expect(decoded.frameCount == 48_000)

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

        try await service.mix(
            micURL: micURL,
            appURL: nil,
            micStartHostTime: HostNanoseconds(nanoseconds: 2_000_000_000),
            appStartHostTime: nil,
            into: outputURL
        )

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 1)
        #expect(decoded.sampleRate == 48_000)
        #expect(decoded.frameCount == 24_000)
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

        try await service.mix(
            micURL: micURL,
            appURL: nil,
            micStartHostTime: HostNanoseconds(nanoseconds: 2_000_000_000),
            appStartHostTime: nil,
            into: outputURL
        )

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 1)
        #expect(decoded.sampleRate == 48_000)
        #expect(decoded.frameCount == 24_000)
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

        try await service.mix(
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 1_500_000_000),
            into: outputURL
        )

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 2)
        #expect(decoded.sampleRate == 48_000)
        #expect(decoded.frameCount == 60_000)

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
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
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

        try await service.mix(
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            into: outputURL
        )

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

        try await service.mix(
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            into: outputURL
        )

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

        try await service.mix(
            micURL: micURL,
            appURL: nil,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: nil,
            into: outputURL,
            deleteSourceFiles: false
        )

        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(FileManager.default.fileExists(atPath: micURL.path))
    }

    private struct DecodedPCM {
        let sampleRate: Double
        let channelCount: Int
        let frameCount: Int
        let channelSamples: [[Float]]
    }

    @Test(arguments: ["Recording Mar 28 at 14-30 a3", "2026-03-28 14-30"])
    func testCoordinatorPersistsMixdownInEitherFolderNameFormat(folderName: String) async throws {
        let folder = tempDirectoryURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let micURL = folder.appendingPathComponent("mic.wav")
        let mixdownURL = folder.appendingPathComponent("recording.m4a")
        try writeMonoWAV(samples: Array(repeating: Float(0.25), count: 48_000), to: micURL)
        try ensureReadableAudioFile(at: micURL)

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let session = RecordingSession(duration: 1, micAudioURL: micURL.path, title: folderName, status: .recorded)
        context.insert(session)
        try context.save()

        let coordinator = RecordingMixdownCoordinator(
            workspaceService: MockWorkspaceService(),
            modelContainer: container
        )
        let committed = await coordinator.runMixdown(
            sessionID: session.id,
            micURL: micURL,
            appURL: nil,
            mixdownURL: mixdownURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: nil
        )

        let persisted = try #require(try RecordingSession.fetch(id: session.id, in: ModelContext(container)))
        #expect(committed)
        #expect(persisted.mixdownURL == mixdownURL.path)
        #expect(FileManager.default.fileExists(atPath: mixdownURL.path))
        #expect(FileManager.default.fileExists(atPath: micURL.path))
    }

    @Test
    func testCoordinatorKeepsInputsWhenTheMixdownCannotBeSaved() async throws {
        let folder = tempDirectoryURL.appendingPathComponent("unsaved", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let micURL = folder.appendingPathComponent("mic.wav")
        let sidecarURL = AudioFileStreamer.timingSidecarURL(for: micURL)
        let mixdownURL = folder.appendingPathComponent("recording.m4a")
        try writeMonoWAV(samples: Array(repeating: Float(0.25), count: 48_000), to: micURL)
        _ = FileManager.default.createFile(atPath: sidecarURL.path, contents: Data("timing".utf8))

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let coordinator = RecordingMixdownCoordinator(
            workspaceService: MockWorkspaceService(),
            modelContainer: container
        )
        // No session with this ID exists, so saving the location fails after the export.
        let committed = await coordinator.runMixdown(
            sessionID: UUID(),
            micURL: micURL,
            appURL: nil,
            mixdownURL: mixdownURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: nil
        )

        #expect(!committed)
        #expect(FileManager.default.fileExists(atPath: mixdownURL.path))
        #expect(FileManager.default.fileExists(atPath: micURL.path))
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    @Test
    func testLegacyOffsetIsCorrectOnANonUnitTimebase() async {
        let timebase = HostClock.Timebase(numer: 125, denom: 3)
        let offset = await AudioMixdownService().computeOffsetSamples(
            micStartHostTime: HostNanoseconds(machTicks: 24_000_000, timebase: timebase),
            appStartHostTime: HostNanoseconds(machTicks: 36_000_000, timebase: timebase)
        )

        #expect(offset == 24_000)
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

    /// Reads the whole file in chunks bounded by its length. A single `read(into:)` sized to the
    /// file returns whole 512-frame packets only, so it drops the tail of a 24,000-frame file.
    private func decodePCM(from url: URL) throws -> DecodedPCM {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        var channelSamples = Array(repeating: [Float](), count: channelCount)

        while file.framePosition < file.length {
            let framesToRead = AVAudioFrameCount(min(Int64(4_096), file.length - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead),
                  let channelData = buffer.floatChannelData else {
                throw RecordingError.failedToStart("Failed to decode mixed output for tests.")
            }
            try file.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0 else { break }
            for channelIndex in 0..<channelCount {
                channelSamples[channelIndex].append(
                    contentsOf: UnsafeBufferPointer(start: channelData[channelIndex], count: Int(buffer.frameLength))
                )
            }
        }

        let frameCount = channelSamples.first?.count ?? 0
        return DecodedPCM(
            sampleRate: format.sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            channelSamples: channelSamples
        )
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
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: 1
        ) else {
            throw RecordingError.failedToStart("Probe buffer allocation failed.")
        }
        try file.read(into: buffer, frameCount: 1)
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
