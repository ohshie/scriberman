import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// Mixdown and recovery of files written through the pause clock, on every path a mixdown can take.
@Suite(.enabled(if: AudioIOAvailability.isAvailable, AudioIOAvailability.unavailableReason))
struct RecordingPauseMixdownTests {
    enum Path: String, CaseIterable, Sendable {
        case timeline, constantOffset, missingMicSidecar, missingBothSidecars, corruptSidecar, inconsistentSidecar
    }

    private static let start: UInt64 = 10_000_000_000

    /// Mic and app captured through their handlers: 200 ms, a 500 ms pause starting 7 ms into a
    /// buffer, 200 ms, a 300 ms pause, 200 ms. The app starts 60 ms after the mic. Both sources are
    /// silent apart from one marker frame each per kept stretch, at the same capture time, and a
    /// full-scale value during the pauses.
    private final class Recording {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gates = RecordingCaptureGates()
        let micStreamer = AudioFileStreamer(label: "mic")
        let appStreamer = AudioFileStreamer(label: "app")
        let mic: MicStreamOutputHandler
        let app: AppAudioStreamOutputHandler
        var micURL: URL { root.appendingPathComponent("mic.wav") }
        var appURL: URL { root.appendingPathComponent("app.wav") }

        private final class Anchor: @unchecked Sendable {
            private let lock = NSLock()
            private var value: HostNanoseconds?
            func set(_ time: HostNanoseconds) { lock.withLock { value = value ?? time } }
            var time: HostNanoseconds? { lock.withLock { value } }
        }
        private let micAnchorBox = Anchor()
        private let appAnchorBox = Anchor()
        var micAnchor: HostNanoseconds? { micAnchorBox.time }
        var appAnchor: HostNanoseconds? { appAnchorBox.time }

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            mic = MicStreamOutputHandler(streamer: micStreamer, gate: gates.mic)
            app = AppAudioStreamOutputHandler(streamer: appStreamer, gate: gates.app)
            mic.configureOutput(url: micURL)
            app.configureOutput(url: appURL)
            mic.onFirstBufferHostTime = { [micAnchorBox] in micAnchorBox.set($0) }
            app.onFirstBufferHostTime = { [appAnchorBox] in appAnchorBox.set($0) }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Feeds both sources over `[from, to)` ms, each buffer 20 ms.
        func feed(fromMs: Int, toMs: Int, value: (_ ms: Double, _ source: AudioSource) -> Float) throws {
            for time in stride(from: fromMs, to: toMs, by: 20) {
                for source in [AudioSource.mic, .app] where source == .mic || time >= 60 {
                    let values = (0..<960).map { value(Double(time) + Double($0) / 48, source) }
                    let buffer = try CaptureAudioGateTests.makeSampleBuffer(
                        values, sampleRate: 48_000, hostTime: RecordingPauseMixdownTests.host(ms: time)
                    )
                    if source == .mic {
                        mic.processSampleBufferForTesting(buffer)
                    } else {
                        app.processSampleBufferForTesting(buffer)
                    }
                }
            }
        }

        func close() {
            mic.closeOutput()
            app.closeOutput()
        }
    }

    private static func host(ms: Int) -> HostNanoseconds {
        HostNanoseconds(nanoseconds: start + UInt64(ms) * 1_000_000)
    }

    /// Feeds the whole recording. Each pause is set when its time comes, as it is when recording.
    private func record(_ recording: Recording) throws {
        let clock = recording.gates.clock
        let pauses = [(207, 707), (907, 1_207)]
        // Capture times, in ms, of the marker frames.
        let markers = [100.0, 800, 1_300]
        func value(_ ms: Double, _ source: AudioSource) -> Float {
            if pauses.contains(where: { ms >= Double($0.0) - 1e-6 && ms < Double($0.1) - 1e-6 }) { return 1 }
            return markers.contains { abs(ms - $0) < 1e-6 } ? 0.25 : 0
        }
        try recording.feed(fromMs: 0, toMs: 200, value: value)
        clock.pause { Self.host(ms: 207) }
        try recording.feed(fromMs: 200, toMs: 700, value: value)
        clock.resume { Self.host(ms: 707) }
        try recording.feed(fromMs: 700, toMs: 900, value: value)
        clock.pause { Self.host(ms: 907) }
        try recording.feed(fromMs: 900, toMs: 1_200, value: value)
        clock.resume { Self.host(ms: 1_207) }
        try recording.feed(fromMs: 1_200, toMs: 1_400, value: value)
        recording.close()
    }

    @Test(arguments: Path.allCases)
    func mixdownHasNoPausedAudioNoSilenceInItsPlaceAndAlignedSources(path: Path) async throws {
        let recording = try Recording()
        try record(recording)
        let micSidecar = AudioFileStreamer.timingSidecarURL(for: recording.micURL)
        let appSidecar = AudioFileStreamer.timingSidecarURL(for: recording.appURL)
        switch path {
        case .timeline, .constantOffset:
            break
        case .missingMicSidecar:
            try FileManager.default.removeItem(at: micSidecar)
        case .missingBothSidecars:
            try FileManager.default.removeItem(at: micSidecar)
            try FileManager.default.removeItem(at: appSidecar)
        case .corruptSidecar:
            try Data("not json".utf8).write(to: appSidecar)
        case .inconsistentSidecar:
            let wrong = CaptureTimingSidecar(
                sampleRate: 48_000,
                segments: [AudioCaptureSegment(startHostTimeNanos: Self.start, frameCount: 1)]
            )
            try JSONEncoder().encode(wrong).write(to: micSidecar)
        }
        #expect(recording.micAnchor == Self.host(ms: 0))
        #expect(recording.appAnchor == Self.host(ms: 60))

        let output = recording.root.appendingPathComponent("mix.caf")
        try await AudioMixdownService(outputFormat: .linearPCMCaf).mix(
            micURL: recording.micURL,
            appURL: recording.appURL,
            micStartHostTime: try #require(recording.micAnchor),
            appStartHostTime: recording.appAnchor,
            into: output,
            deleteSourceFiles: false,
            timelineMixdown: path != .constantOffset
        )
        let mix = try CaptureAudioGateTests.readSamples(output)

        // 1 400 ms captured, 800 ms paused.
        #expect(mix.count == 28_800)
        // Capture times 100, 800 and 1 300 ms become 100, 300 and 500 ms of recording. The sources
        // are aligned when each marker is one frame holding both.
        #expect(mix.indices.filter { abs(mix[$0]) > 0.01 } == [4_800, 14_400, 24_000])
        let peak = try #require(mix.map(abs).max())
        #expect(peak < 0.75)
        #expect(Set(mix.indices.filter { abs(mix[$0]) > 0.01 }.map { mix[$0] }).count == 1)
    }

    /// A mic-only recording whose mic delivers nothing for 1 s while it switches devices (a removal,
    /// then the default). The gap stays at its real length in the mixdown, so later audio is not
    /// pulled earlier against screen video or the transcript.
    @Test
    func aMicOnlySwitchGapKeepsItsRealLengthInTheMixdown() async throws {
        let recording = try Recording()
        let markers = [100.0, 1_300]
        for time in stride(from: 0, to: 1_400, by: 20) where time < 200 || time >= 1_200 {
            let values = (0..<960).map { index -> Float in
                markers.contains { abs(Double(time) + Double(index) / 48 - $0) < 1e-6 } ? 0.25 : 0
            }
            recording.mic.processSampleBufferForTesting(
                try CaptureAudioGateTests.makeSampleBuffer(values, sampleRate: 48_000, hostTime: Self.host(ms: time))
            )
        }
        recording.close()
        #expect(recording.micAnchor == Self.host(ms: 0))

        let output = recording.root.appendingPathComponent("mix.caf")
        try await AudioMixdownService(outputFormat: .linearPCMCaf).mix(
            micURL: recording.micURL, appURL: nil,
            micStartHostTime: try #require(recording.micAnchor), appStartHostTime: nil,
            into: output, deleteSourceFiles: false, timelineMixdown: true
        )
        let mix = try CaptureAudioGateTests.readSamples(output)
        #expect(mix.count == 67_200)
        #expect(mix.indices.filter { abs(mix[$0]) > 0.01 } == [4_800, 62_400])
    }

    /// What distinguishes "both sources in one frame" above from one source alone.
    @Test
    func aMarkerInOneSourceAloneMixesLower() async throws {
        let recording = try Recording()
        try recording.feed(fromMs: 0, toMs: 200) { ms, source in
            if abs(ms - 100) < 1e-6 { return 0.25 }
            return abs(ms - 150) < 1e-6 && source == .mic ? 0.25 : 0
        }
        recording.close()
        let output = recording.root.appendingPathComponent("mix.caf")
        try await AudioMixdownService(outputFormat: .linearPCMCaf).mix(
            micURL: recording.micURL, appURL: recording.appURL,
            micStartHostTime: Self.host(ms: 0), appStartHostTime: Self.host(ms: 60),
            into: output, deleteSourceFiles: false, timelineMixdown: true
        )
        let mix = try CaptureAudioGateTests.readSamples(output)
        #expect(mix[4_800] > mix[7_200])
    }

    // MARK: - Recovery

    enum Crash: String, CaseIterable, Sendable {
        case duringPause, afterResume, duringFinalization
    }

    /// Copies the files as a terminated process leaves them and recovers the copy.
    @Test(arguments: Crash.allCases)
    func recoveryAfterTerminationContainsNoPausedAudio(crash: Crash) async throws {
        let recording = try Recording()
        // Kept audio is a quiet 440 Hz tone; the pause is a loud 6 kHz one.
        func value(_ ms: Double, _: AudioSource) -> Float {
            let isPaused = ms >= 1_007 - 1e-6 && ms < 2_007 - 1e-6
            return isPaused
                ? 0.9 * sinf(Float(2 * Double.pi * 6 * ms))
                : 0.2 * sinf(Float(2 * Double.pi * 0.44 * ms))
        }
        try recording.feed(fromMs: 0, toMs: 1_000, value: value)
        recording.gates.clock.pause { Self.host(ms: 1_007) }
        try recording.feed(fromMs: 1_000, toMs: 2_000, value: value)
        var keptFrames: Int64 = 48_336
        if crash != .duringPause {
            recording.gates.clock.resume { Self.host(ms: 2_007) }
            try recording.feed(fromMs: 2_000, toMs: 3_000, value: value)
            keptFrames = 96_000
        }
        let deadline = Date().addingTimeInterval(10)
        while recording.micStreamer.framesWritten < keptFrames || recording.appStreamer.framesWritten < keptFrames - 2_880,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if crash == .duringFinalization { recording.close() }

        let folder = recording.root.appendingPathComponent("crashed", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let micURL = folder.appendingPathComponent("mic.wav")
        let appURL = folder.appendingPathComponent("app.wav")
        try FileManager.default.copyItem(at: recording.micURL, to: micURL)
        try FileManager.default.copyItem(at: recording.appURL, to: appURL)
        // The process ended after the mic sidecar was written and before the app's.
        if crash == .duringFinalization {
            try FileManager.default.copyItem(
                at: AudioFileStreamer.timingSidecarURL(for: recording.micURL),
                to: AudioFileStreamer.timingSidecarURL(for: micURL)
            )
        } else {
            #expect(AudioFileStreamer.loadTimingSidecar(for: recording.micURL) == nil)
        }

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let session = RecordingSession(
            createdAt: Date(timeIntervalSinceNow: -600), duration: 0,
            micAudioURL: micURL.path, appAudioURL: appURL.path, title: "Crashed", status: .recording
        )
        context.insert(session)
        try context.save()
        let sessionID = session.id
        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = Workspace(rootURL: recording.root)
        await RecordingRecoveryService(
            workspaceService: workspaceService, modelContainer: container, retireSources: { _, _ in }
        ).sweepIncompleteSessions()

        let recovered = try #require(try RecordingSession.fetch(id: sessionID, in: ModelContext(container)))
        let mix = try CaptureAudioGateTests.readSamples(URL(fileURLWithPath: try #require(recovered.mixdownURL)))
        // AAC adds priming and padding of at most a few packets; the pause is 48 000 frames.
        #expect(mix.count > 24_000)
        #expect(mix.count < Int(keptFrames) + 8_192)
        #expect(level(of: 440, in: mix) > 0.05)
        #expect(level(of: 6_000, in: mix) < 0.005)
    }

    @Test
    func theSentinelLevelWouldBeSeen() {
        let tone = (0..<48_000).map { 0.9 * sinf(Float(2 * Double.pi * 6_000 * Double($0) / 48_000)) }
        #expect(level(of: 6_000, in: tone) > 0.5)
    }

    /// Highest amplitude of one frequency in any 20 ms window.
    private func level(of frequency: Double, in samples: [Float]) -> Double {
        let size = 960
        return stride(from: 0, through: samples.count - size, by: size).map { offset -> Double in
            var real = 0.0, imaginary = 0.0
            for index in 0..<size {
                let phase = 2 * Double.pi * frequency * Double(index) / 48_000
                let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(size))
                real += Double(samples[offset + index]) * cos(phase) * window
                imaginary += Double(samples[offset + index]) * sin(phase) * window
            }
            return 4 * (real * real + imaginary * imaginary).squareRoot() / Double(size)
        }.max() ?? 0
    }
}
