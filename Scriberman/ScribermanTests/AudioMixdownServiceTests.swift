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
    func testAgreeingSidecarProducesOneChannelOutput() async throws {
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
        #expect(decoded.channelCount == 1)
    }

    /// Writes a `.timing` sidecar with the given segment start times, each `framesPerSegment` long.
    private func writeSidecar(for audioURL: URL, segmentStarts: [UInt64], framesPerSegment: Int = 960) throws {
        let segments = segmentStarts.map { AudioCaptureSegment(startHostTimeNanos: $0, frameCount: framesPerSegment) }
        let sidecar = CaptureTimingSidecar(sampleRate: 48_000, segments: segments)
        let data = try JSONEncoder().encode(sidecar)
        try data.write(to: AudioFileStreamer.timingSidecarURL(for: audioURL), options: .atomic)
    }

    /// Timeline path. The mic has 50 contiguous 20 ms segments from 1.0 s. The app starts at 1.5 s
    /// (frame 24,000) with 10 segments, misses 100 ms (4,800 frames), then has 10 more ending at
    /// frame 48,000. The gap is mic alone, as the right channel was silent there in the stereo
    /// mixdown.
    @Test
    func testTimelineMixKeepsLaterAppStartAndGapSilencePositions() async throws {
        let service = AudioMixdownService(outputFormat: .linearPCMCaf)
        let micURL = tempDirectoryURL.appendingPathComponent("mic-gap.wav")
        let appURL = tempDirectoryURL.appendingPathComponent("app-gap.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("gap.caf")

        try writeFloatWAV(samples: Array(repeating: Float(0.125), count: 48_000), to: micURL)
        try writeFloatWAV(samples: Array(repeating: Float(0.5), count: 19_200), to: appURL)
        try writeSidecar(
            for: micURL,
            segmentStarts: (0..<50).map { 1_000_000_000 + UInt64($0) * 20_000_000 }
        )
        let beforeGap = (0..<10).map { 1_500_000_000 + UInt64($0) * 20_000_000 }
        let afterGap = (0..<10).map { 1_800_000_000 + UInt64($0) * 20_000_000 }
        try writeSidecar(for: appURL, segmentStarts: beforeGap + afterGap)

        try await service.mix(
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 1_500_000_000),
            into: outputURL
        )

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 1)
        #expect(decoded.frameCount == 48_000)
        let samples = decoded.channelSamples[0]
        #expect(samples[0..<24_000].allSatisfy { $0 == 0.125 })
        #expect(samples[24_000..<33_600].allSatisfy { $0 == 0.625 })
        #expect(samples[33_600..<38_400].allSatisfy { $0 == 0.125 })
        #expect(samples[38_400..<48_000].allSatisfy { $0 == 0.625 })
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
        #expect(decoded.channelCount == 1)
    }

    /// The mode passed in wins over the stored flag. The sidecars say both sources started
    /// together; the host times say the app started half a second late. Only the timeline path
    /// trusts the sidecars, so the opening of the mono-summed output tells the two modes apart:
    /// mic plus app (0.25 − 0.55) on the timeline path, mic alone (0.25) on the legacy path.
    @Test(arguments: [true, false])
    func testRequestedTimelineModeWinsOverTheStoredFlag(timeline: Bool) async throws {
        let suiteName = "AudioMixdownServiceTests-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        store.set(!timeline, forKey: AudioSyncConfig.FlagDefinitions.shipped.timelineMixdown.key)
        let service = AudioMixdownService(outputFormat: .linearPCMCaf, audioSyncConfig: AudioSyncConfig(store: store))
        let micURL = tempDirectoryURL.appendingPathComponent("mic-mode.wav")
        let appURL = tempDirectoryURL.appendingPathComponent("app-mode.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("mode.caf")

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
            appStartHostTime: HostNanoseconds(nanoseconds: 1_500_000_000),
            into: outputURL,
            timelineMixdown: timeline
        )

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 1)
        let opening = mean(decoded.channelSamples[0].prefix(12_000))
        if timeline {
            #expect(abs(opening - -0.30) < 0.01)
        } else {
            #expect(abs(opening - 0.25) < 0.01)
        }
    }

    /// Below the ceiling the limiter leaves every frame alone, so each output sample is the mic
    /// sample plus the app sample. Float WAV inputs and the PCM output carry these values exactly.
    @Test
    func testMixWithTwoSourcesSumsMicAndAppIntoOneChannel() async throws {
        let service = AudioMixdownService(outputFormat: .linearPCMCaf)
        let micURL = tempDirectoryURL.appendingPathComponent("mic.wav")
        let appURL = tempDirectoryURL.appendingPathComponent("app.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("recording.caf")

        let mic = (0..<48_000).map { $0.isMultiple(of: 2) ? Float(0.25) : Float(-0.125) }
        try writeFloatWAV(samples: mic, to: micURL)
        try writeFloatWAV(samples: Array(repeating: Float(-0.5), count: 48_000), to: appURL)

        try await service.mix(
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            into: outputURL
        )

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 1)
        #expect(decoded.sampleRate == 48_000)
        #expect(decoded.frameCount == 48_000)
        let samples = decoded.channelSamples[0]
        #expect(samples.enumerated().allSatisfy { index, sample in
            sample == (index.isMultiple(of: 2) ? Float(-0.25) : Float(-0.625))
        })
    }

    /// A 10 ms burst where mic and app together reach 1.0 (0 dBFS). −1 dBFS is 0.8912509 linear.
    /// Frames well before the burst (outside the ~5 ms look-ahead) and well after it (past the
    /// ~50 ms release) keep the plain sum of 0.5.
    @Test
    func testCoincidentPeaksAreLimitedToMinusOneDBFS() async throws {
        let service = AudioMixdownService(outputFormat: .linearPCMCaf)
        let micURL = tempDirectoryURL.appendingPathComponent("mic.wav")
        let appURL = tempDirectoryURL.appendingPathComponent("app.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("recording.caf")

        var app = Array(repeating: Float(0.25), count: 48_000)
        for index in 24_000..<24_480 {
            app[index] = 0.75
        }
        try writeFloatWAV(samples: Array(repeating: Float(0.25), count: 48_000), to: micURL)
        try writeFloatWAV(samples: app, to: appURL)

        try await service.mix(
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            into: outputURL
        )

        let samples = try decodePCM(from: outputURL).channelSamples[0]
        #expect(samples.count == 48_000)
        #expect(samples.allSatisfy { abs($0) <= 0.8912510 })
        #expect(samples[24_000..<24_480].allSatisfy { $0 >= 0.85 })
        #expect(samples[0..<23_000].allSatisfy { $0 == 0.5 })
        #expect(samples[30_000..<48_000].allSatisfy { $0 == 0.5 })
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

    /// Legacy offset path. The app starts 0.5 s (24,000 frames) after the mic and runs 12,000
    /// frames past the mic's end, so the output is 48,000 frames: mic alone, then both, then app
    /// alone.
    @Test
    func testLaterStartingLongerAppSourceKeepsPositionsAndTotalLength() async throws {
        let service = AudioMixdownService(outputFormat: .linearPCMCaf)
        let micURL = tempDirectoryURL.appendingPathComponent("mic.wav")
        let appURL = tempDirectoryURL.appendingPathComponent("app.wav")
        let outputURL = tempDirectoryURL.appendingPathComponent("recording.caf")

        try writeFloatWAV(samples: Array(repeating: Float(0.125), count: 36_000), to: micURL)
        try writeFloatWAV(samples: Array(repeating: Float(0.5), count: 24_000), to: appURL)

        try await service.mix(
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 1_500_000_000),
            into: outputURL
        )

        let decoded = try decodePCM(from: outputURL)
        #expect(decoded.channelCount == 1)
        #expect(decoded.frameCount == 48_000)
        let samples = decoded.channelSamples[0]
        #expect(samples[0..<24_000].allSatisfy { $0 == 0.125 })
        #expect(samples[24_000..<36_000].allSatisfy { $0 == 0.625 })
        #expect(samples[36_000..<48_000].allSatisfy { $0 == 0.5 })
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
            appStartHostTime: nil,
            timelineMixdown: true
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
            appStartHostTime: nil,
            timelineMixdown: true
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

    /// Float32 WAV, so test values reach the mixdown without 16-bit quantization.
    private func writeFloatWAV(samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channelData = buffer.floatChannelData else {
            throw RecordingError.failedToStart("Failed to build float WAV buffer for tests.")
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress {
                channelData[0].update(from: baseAddress, count: samples.count)
            }
        }
        try file.write(from: buffer)
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
