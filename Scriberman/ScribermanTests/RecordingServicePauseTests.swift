import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit
import SwiftData
import Testing
@testable import Scriberman

/// Pause and resume on `RecordingService`, with audio delivered through the capture handlers the
/// service itself created.
struct RecordingServicePauseTests {
    private static let before: Float = 0.25
    private static let paused: Float = 0.9
    private static let after: Float = -0.25

    // MARK: - Fixture

    /// Wall and host time of the recording under test, moved by hand.
    private final class ManualTime: @unchecked Sendable {
        private let lock = NSLock()
        private var millis: UInt64 = 0
        private static let hostBase: UInt64 = 1_000_000_000_000
        private static let dateBase = Date(timeIntervalSince1970: 1_774_708_200)

        func advance(ms: UInt64) { lock.withLock { millis += ms } }
        var host: HostNanoseconds {
            HostNanoseconds(nanoseconds: Self.hostBase + lock.withLock { millis } * 1_000_000)
        }
        var date: Date { Self.dateBase.addingTimeInterval(Double(lock.withLock { millis }) / 1_000) }
    }

    /// Runs `onStop` while the stream stops, when a real stream still drains queued buffers.
    private final class StubStream: UnifiedCaptureStreaming, @unchecked Sendable {
        let onStop: @Sendable () -> Void
        init(onStop: @escaping @Sendable () -> Void) { self.onStop = onStop }
        func addStreamOutput(_: SCStreamOutput, type _: SCStreamOutputType, sampleHandlerQueue _: DispatchQueue?) throws {}
        func startCapture() async throws {}
        func stopCapture() async throws { onStop() }
        func updateConfiguration(_: SCStreamConfiguration) async throws {}
    }

    /// The sessions the service started, newest last.
    private final class Captures: @unchecked Sendable {
        private let lock = NSLock()
        private var _unified: [UnifiedCaptureSession] = []
        private var _app: [AppAudioCaptureSession] = []
        private var _onStop: (@Sendable () -> Void)?
        var unified: [UnifiedCaptureSession] { lock.withLock { _unified } }
        var app: [AppAudioCaptureSession] { lock.withLock { _app } }
        func setOnStop(_ body: @escaping @Sendable () -> Void) { lock.withLock { _onStop = body } }

        func start(_ start: RecordingService.CaptureSessionStart) async throws {
            let stream = StubStream { [weak self] in
                guard let self else { return }
                self.lock.withLock { self._onStop }?()
            }
            switch start {
            case .unified(let session):
                lock.withLock { _unified.append(session) }
                try await session.start(stream: stream)
            case .appAudio(let session):
                lock.withLock { _app.append(session) }
                try await session.start(stream: stream)
            }
        }
    }

    /// An engine microphone whose tap is fed by the test.
    private final class TapMicController: MicCaptureControlling, @unchecked Sendable {
        private(set) var taps: [EngineMicTap] = []
        private var running = false

        func startCapture(
            deviceID _: AudioDeviceID?,
            targetFormat: AVAudioFormat,
            micFileURL _: URL,
            micStreamer: AudioFileStreamer,
            gate: CaptureAudioGate,
            voiceProcessingEnabled _: Bool,
            applyVoiceProcessing _: @Sendable (AVAudioInputNode, Bool) -> Void,
            onFirstHostTime: @escaping @Sendable (HostNanoseconds) -> Void,
            onBuffer: @escaping MicBufferHandler
        ) throws {
            taps.append(try EngineMicTap(
                inputFormat: targetFormat, targetFormat: targetFormat, micStreamer: micStreamer, gate: gate,
                onFirstHostTime: onFirstHostTime, onBuffer: onBuffer
            ))
            running = true
        }

        func stopCapture() { running = false }
        func retargetDevice(_: AudioDeviceID?) throws {}
        func isCaptureRunning() -> Bool { running }
        func die() { running = false }
    }

    private struct Fixture {
        let service: RecordingService
        let container: ModelContainer
        let workspace: Workspace
        let time: ManualTime
        let captures: Captures
        let mic: TapMicController
        let audio = AsyncStream<LiveAudioChunk>.makeStream()
        let liveClock = LiveCaptureClock()

        func start(appProcessID: pid_t? = nil, unified: Bool = true) async throws -> UUID {
            try await service.startRecording(
                in: workspace,
                appProcessID: appProcessID,
                title: "Paused",
                liveAudioContinuation: audio.continuation,
                liveAudioClock: liveClock,
                audioSyncFlags: AudioSyncFlags(
                    isTimelineMixdownEnabled: true,
                    isUnifiedCaptureEnabled: unified,
                    isCaptureHealthRecoveryEnabled: true
                )
            )
        }

        /// Feeds a 20 ms buffer captured now, and moves time past it.
        func sendMic(_ value: Float) throws {
            try mic.taps.last!.process(CaptureAudioGateTests.makePCM(value20ms(value), sampleRate: 48_000), hostTime: time.host)
            time.advance(ms: 20)
        }

        func sendUnified(_ value: Float, to session: UnifiedCaptureSession) throws {
            let buffer = try CaptureAudioGateTests.makeSampleBuffer(value20ms(value), sampleRate: 48_000, hostTime: time.host)
            session.micHandler.processSampleBufferForTesting(buffer)
            session.appHandler.processSampleBufferForTesting(buffer)
            time.advance(ms: 20)
        }

        func value20ms(_ value: Float) -> [Float] { Array(repeating: value, count: 960) }

        func chunks() async -> [LiveAudioChunk] {
            var chunks: [LiveAudioChunk] = []
            for await chunk in audio.stream { chunks.append(chunk) }
            return chunks
        }

        func session(_ id: UUID) throws -> RecordingSession {
            try #require(try RecordingSession.fetch(id: id, in: ModelContext(container)))
        }

        func remove() { try? FileManager.default.removeItem(at: workspace.rootURL) }
    }

    private func makeFixture() async throws -> Fixture {
        let workspace = Workspace(
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        let time = ManualTime()
        let captures = Captures()
        let mic = TapMicController()
        let settings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: settings,
            micCaptureController: mic,
            mixdownCoordinator: NoMixdown(),
            screenVideoMuxer: NoMux(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            now: { time.date },
            hostNow: { time.host },
            captureSessionStarter: { try await captures.start($0) }
        )
        return Fixture(
            service: service, container: container, workspace: workspace, time: time, captures: captures, mic: mic
        )
    }

    /// Reports no mixdown, so the finalizer keeps the raw files the tests read.
    private struct NoMixdown: RecordingMixdownCoordinating {
        func runMixdown(
            sessionID _: UUID, micURL _: URL, appURL _: URL?, mixdownURL _: URL,
            micStartHostTime _: HostNanoseconds, appStartHostTime _: HostNanoseconds?, timelineMixdown _: Bool
        ) async -> Bool { false }
    }

    private struct NoMux: ScreenVideoMuxing {
        func runMux(request _: ScreenVideoMuxRequest) async {}
    }

    private func samples(_ path: String?) throws -> [Float] {
        try CaptureAudioGateTests.readSamples(URL(fileURLWithPath: try #require(path)))
    }

    private func run(_ value: Float, _ buffers: Int) -> [Float] {
        Array(repeating: value, count: buffers * 960)
    }

    // MARK: - State

    @Test
    func pauseAndResumeAreASubStateOfRecording() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        #expect(await fixture.service.pauseRecording() == false)
        #expect(await fixture.service.resumeRecording() == false)
        #expect(await fixture.service.isPaused() == false)

        _ = try await fixture.start()
        #expect(await fixture.service.resumeRecording())
        #expect(await fixture.service.pauseRecording())
        #expect(await fixture.service.pauseRecording())
        #expect(await fixture.service.isPaused())
        #expect(await fixture.service.isRecording())
        #expect(await fixture.service.resumeRecording())
        #expect(await fixture.service.isPaused() == false)

        #expect(await fixture.service.pauseRecording())
        _ = await fixture.service.stopRecording()
        #expect(await fixture.service.isPaused() == false)
        #expect(await fixture.service.pauseRecording() == false)
        #expect(await fixture.service.resumeRecording() == false)
    }

    @Test
    func aNewRecordingStartsWithoutThePreviousPause() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start()
        _ = await fixture.service.pauseRecording()
        _ = await fixture.service.stopRecording()

        _ = try await fixture.start()
        #expect(await fixture.service.isPaused() == false)
        try fixture.sendMic(Self.before)
        let id = try #require(await fixture.service.stopRecording())
        #expect(try samples(fixture.session(id).micAudioURL) == run(Self.before, 1))
    }

    @Test(arguments: [true, false])
    func levelsReadAsZeroWhilePaused(unified: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: unified ? 1 : nil)
        func send(_ value: Float) throws {
            if unified {
                try fixture.sendUnified(value, to: try #require(fixture.captures.unified.last))
            } else {
                try fixture.sendMic(value)
            }
        }
        try send(Self.before)
        let deadline = Date().addingTimeInterval(5)
        while await fixture.service.audioLevel() == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.service.audioLevel() > 0)

        _ = await fixture.service.pauseRecording()
        try send(Self.paused)
        let levels = await fixture.service.audioLevels()
        #expect(levels.mic == 0)
        #expect(levels.app == 0)
        #expect(await fixture.service.audioLevel() == 0)
        _ = await fixture.service.stopRecording()
    }

    // MARK: - Capture paths

    @Test
    func engineMicRecordsOnlyOutsidePausesAndAcrossAnEngineRestart() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start()
        try fixture.sendMic(Self.before)
        _ = await fixture.service.pauseRecording()
        try fixture.sendMic(Self.paused)
        fixture.mic.die()
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()
        #expect(fixture.mic.taps.count == 2)
        try fixture.sendMic(Self.paused)
        _ = await fixture.service.resumeRecording()
        try fixture.sendMic(Self.after)
        let counts = await fixture.service.captureArrivalCounts()
        #expect(counts.mic == 4)
        #expect(counts.app == nil)

        let id = try #require(await fixture.service.stopRecording())
        let expected = run(Self.before, 1) + run(Self.after, 1)
        #expect(try samples(fixture.session(id).micAudioURL) == expected)
        let chunks = await fixture.chunks()
        #expect(chunks.flatMap(\.samples) == expected)
        // 40 ms of the 60 ms were paused.
        let times = chunks.compactMap { $0.hostTime?.nanoseconds }
        #expect(times[1] - times[0] == 20_000_000)
    }

    @Test
    func unifiedRestartInPlaceKeepsTheClock() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        let original = try #require(fixture.captures.unified.last)
        try fixture.sendUnified(Self.before, to: original)
        _ = await fixture.service.pauseRecording()
        try fixture.sendUnified(Self.paused, to: original)

        #expect(await fixture.service.restartAudioCaptureInPlace())
        let replacement = try #require(fixture.captures.unified.last)
        #expect(replacement !== original)
        #expect(await fixture.service.isPaused())
        try fixture.sendUnified(Self.paused, to: replacement)
        _ = await fixture.service.resumeRecording()
        try fixture.sendUnified(Self.after, to: replacement)
        let counts = await fixture.service.captureArrivalCounts()
        #expect(counts.mic == 4)
        #expect(counts.app == 4)

        let id = try #require(await fixture.service.stopRecording())
        let session = try fixture.session(id)
        let expected = run(Self.before, 1) + run(Self.after, 1)
        for path in [session.micAudioURL, try #require(session.appAudioURL)] {
            #expect(try samples(path) == expected)
            let sidecar = try #require(AudioFileStreamer.loadTimingSidecar(for: URL(fileURLWithPath: path)))
            #expect(sidecar.totalFrames == expected.count)
            #expect(sidecar.segments.count == 2)
            // The 40 ms pause is not an outage.
            #expect(sidecar.segments[1].startHostTimeNanos - sidecar.segments[0].startHostTimeNanos == 20_000_000)
        }
        #expect(await fixture.chunks().allSatisfy { !$0.samples.contains(Self.paused) })
    }

    @Test
    func legacyAppAudioIsGatedByTheRecordingsClock() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, unified: false)
        let app = try #require(fixture.captures.app.last)
        let folder = try #require(
            try FileManager.default.contentsOfDirectory(at: fixture.workspace.rootURL, includingPropertiesForKeys: nil)
                .flatMap { [$0] + ((try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []) }
                .first { FileManager.default.fileExists(atPath: RecordingFileLayout.recordingFileURLs(in: $0).mic.path) }
        )
        app.outputHandler.configureOutput(url: RecordingFileLayout.recordingFileURLs(in: folder).app)
        func sendBoth(_ value: Float) throws {
            app.outputHandler.processSampleBufferForTesting(
                try CaptureAudioGateTests.makeSampleBuffer(fixture.value20ms(value), sampleRate: 48_000, hostTime: fixture.time.host)
            )
            try fixture.sendMic(value)
        }
        try sendBoth(Self.before)
        _ = await fixture.service.pauseRecording()
        try sendBoth(Self.paused)
        _ = await fixture.service.resumeRecording()
        try sendBoth(Self.after)
        #expect(await fixture.service.captureArrivalCounts().app == 3)

        let deadline = Date().addingTimeInterval(5)
        while (await fixture.service.captureFrameCounts().app ?? 0) < 1_920, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let id = try #require(await fixture.service.stopRecording())
        let session = try fixture.session(id)
        let expected = run(Self.before, 1) + run(Self.after, 1)
        #expect(try samples(session.micAudioURL) == expected)
        #expect(try samples(session.appAudioURL) == expected)
    }

    @Test
    func anchorsAreAdjustedAndSkipAFirstBufferInsideAPause() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        let session = try #require(fixture.captures.unified.last)
        let pausedAt = fixture.time.host
        _ = await fixture.service.pauseRecording()
        try fixture.sendUnified(Self.paused, to: session)
        fixture.time.advance(ms: 480)
        _ = await fixture.service.resumeRecording()
        #expect(fixture.liveClock.anchor == nil)
        try fixture.sendUnified(Self.after, to: session)

        let deadline = Date().addingTimeInterval(5)
        while await fixture.service.capturedHostTimes().app == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        while await fixture.service.capturedHostTimes().mic == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let times = await fixture.service.capturedHostTimes()
        #expect(times.mic == pausedAt)
        #expect(times.app == pausedAt)
        #expect(fixture.liveClock.anchor == pausedAt)
        _ = await fixture.service.stopRecording()
    }

    // MARK: - Stop

    @Test(arguments: [true, false])
    func buffersDeliveredWhileStoppingAreCutAtTheStop(whilePaused: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        let session = try #require(fixture.captures.unified.last)
        try fixture.sendUnified(Self.before, to: session)
        if whilePaused {
            _ = await fixture.service.pauseRecording()
            try fixture.sendUnified(Self.paused, to: session)
        }
        // Captured from 10 ms before the stop to 10 ms after it.
        let start = fixture.time.host
        fixture.time.advance(ms: 10)
        let late = try CaptureAudioGateTests.makeSampleBuffer(
            Array(repeating: whilePaused ? Self.paused : Self.before, count: 480) + Array(repeating: Self.paused, count: 480),
            sampleRate: 48_000, hostTime: start
        )
        let afterStop = try CaptureAudioGateTests.makeSampleBuffer(
            fixture.value20ms(Self.paused), sampleRate: 48_000,
            hostTime: HostNanoseconds(nanoseconds: start.nanoseconds + 20_000_000)
        )
        let lateBuffers = LateBuffers(buffers: [late, afterStop])
        fixture.captures.setOnStop {
            for buffer in lateBuffers.buffers {
                session.micHandler.processSampleBufferForTesting(buffer)
                session.appHandler.processSampleBufferForTesting(buffer)
            }
        }

        let id = try #require(await fixture.service.stopRecording())
        let saved = try fixture.session(id)
        let expected = [Float](repeating: Self.before, count: whilePaused ? 960 : 1_440)
        #expect(try samples(saved.micAudioURL) == expected)
        #expect(try samples(saved.appAudioURL) == expected)
        for chunk in await fixture.chunks() { #expect(!chunk.samples.contains(Self.paused)) }
    }

    private struct LateBuffers: @unchecked Sendable {
        let buffers: [CMSampleBuffer]
    }

    @Test
    func savedDurationExcludesPauses() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start()
        try fixture.sendMic(Self.before)
        fixture.time.advance(ms: 9_980)
        _ = await fixture.service.pauseRecording()
        fixture.time.advance(ms: 60_000)
        _ = await fixture.service.resumeRecording()
        fixture.time.advance(ms: 5_000)
        let id = try #require(await fixture.service.stopRecording())
        #expect(abs(try fixture.session(id).duration - 15) < 0.001)
    }

    @Test
    func savedDurationEndsAtThePauseWhenStoppedWhilePaused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))
        fixture.time.advance(ms: 9_980)
        _ = await fixture.service.pauseRecording()
        fixture.time.advance(ms: 60_000)
        // Teardown takes time; it belongs to neither the recording nor the pause.
        let time = fixture.time
        fixture.captures.setOnStop { time.advance(ms: 3_000) }
        let id = try #require(await fixture.service.stopRecording())
        #expect(abs(try fixture.session(id).duration - 10) < 0.001)
    }

    @Test
    func aLongPauseIsNotMissingCoverage() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start()
        for _ in 0..<100 { try fixture.sendMic(Self.before) }
        let deadline = Date().addingTimeInterval(10)
        while (await fixture.service.captureFrameCounts().mic ?? 0) < 96_000, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await fixture.service.pauseRecording()
        fixture.time.advance(ms: 600_000)
        let id = try #require(await fixture.service.stopRecording())
        let session = try fixture.session(id)
        #expect(session.partiallyCoveredSources == nil)
        #expect(abs(session.duration - 2) < 0.001)
    }

    @Test
    func anOutageOutsideAPauseIsStillMissingCoverage() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start()
        try fixture.sendMic(Self.before)
        fixture.time.advance(ms: 60_000)
        _ = await fixture.service.pauseRecording()
        fixture.time.advance(ms: 600_000)
        let id = try #require(await fixture.service.stopRecording())
        #expect(try fixture.session(id).partiallyCoveredSources == ["mic"])
    }

    // MARK: - Pause markers

    /// Everything the service sends to live transcription, read while the recording runs.
    private final class LiveEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [LiveAudioChunk] = []
        private var task: Task<Void, Never>?

        init(_ stream: AsyncStream<LiveAudioChunk>) {
            task = Task { [weak self] in
                for await event in stream { self?.lock.withLock { self?.events.append(event) } }
            }
        }

        var all: [LiveAudioChunk] { lock.withLock { events } }

        func markers(_ source: AudioSource) -> [Int] {
            all.filter { $0.source == source }.compactMap(\.pauseNumber)
        }

        /// Waits until `source` has sent `count` markers, or times out.
        func waitForMarkers(_ source: AudioSource, count: Int) async -> [Int] {
            let deadline = Date().addingTimeInterval(5)
            while markers(source).count < count, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return markers(source)
        }

        func finished() async -> [LiveAudioChunk] {
            await task?.value
            return all
        }
    }

    /// Kinds of the source's events in order: "audio" or the marker number.
    private func sequence(_ events: [LiveAudioChunk], _ source: AudioSource) -> [String] {
        events.filter { $0.source == source }.map { $0.pauseNumber.map(String.init) ?? "audio" }
    }

    @Test
    func aSourceThatDeliversNothingDuringAPauseIsMarkedAtResume() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let live = LiveEvents(fixture.audio.stream)
        _ = try await fixture.start(appProcessID: 1)
        let session = try #require(fixture.captures.unified.last)
        try fixture.sendUnified(Self.before, to: session)
        _ = await fixture.service.pauseRecording()
        // Only the microphone keeps delivering.
        session.micHandler.processSampleBufferForTesting(
            try CaptureAudioGateTests.makeSampleBuffer(fixture.value20ms(Self.paused), sampleRate: 48_000, hostTime: fixture.time.host)
        )
        fixture.time.advance(ms: 20)
        #expect(await live.waitForMarkers(.mic, count: 1) == [1])
        #expect(live.markers(.app).isEmpty)

        _ = await fixture.service.resumeRecording()
        #expect(await live.waitForMarkers(.app, count: 1) == [1])
        try fixture.sendUnified(Self.after, to: session)
        _ = await fixture.service.stopRecording()
        let events = await live.finished()
        #expect(sequence(events, .mic) == ["audio", "1", "audio"])
        #expect(sequence(events, .app) == ["audio", "1", "audio"])
    }

    @Test
    func sourcesThatDeliverNothingAreMarkedAtAStopWhilePaused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let live = LiveEvents(fixture.audio.stream)
        _ = try await fixture.start(appProcessID: 1)
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))
        _ = await fixture.service.pauseRecording()
        _ = await fixture.service.stopRecording()
        let events = await live.finished()
        #expect(sequence(events, .mic) == ["audio", "1"])
        #expect(sequence(events, .app) == ["audio", "1"])
    }

    @Test
    func aRestartInPlaceDuringAPauseMarksBothSources() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let live = LiveEvents(fixture.audio.stream)
        _ = try await fixture.start(appProcessID: 1)
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))
        _ = await fixture.service.pauseRecording()
        #expect(await fixture.service.restartAudioCaptureInPlace())
        #expect(await live.waitForMarkers(.mic, count: 1) == [1])
        #expect(await live.waitForMarkers(.app, count: 1) == [1])

        try fixture.sendUnified(Self.paused, to: try #require(fixture.captures.unified.last))
        _ = await fixture.service.resumeRecording()
        try fixture.sendUnified(Self.after, to: try #require(fixture.captures.unified.last))
        _ = await fixture.service.stopRecording()
        let events = await live.finished()
        #expect(sequence(events, .mic) == ["audio", "1", "audio"])
        #expect(sequence(events, .app) == ["audio", "1", "audio"])
    }

    @Test
    func anEngineRecoveryDuringAPauseMarksTheMicrophone() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let live = LiveEvents(fixture.audio.stream)
        _ = try await fixture.start()
        try fixture.sendMic(Self.before)
        _ = await fixture.service.pauseRecording()
        fixture.mic.die()
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()
        #expect(fixture.mic.taps.count == 2)
        #expect(await live.waitForMarkers(.mic, count: 1) == [1])

        try fixture.sendMic(Self.paused)
        _ = await fixture.service.resumeRecording()
        try fixture.sendMic(Self.after)
        _ = await fixture.service.stopRecording()
        let events = await live.finished()
        #expect(sequence(events, .mic) == ["audio", "1", "audio"])
        #expect(!events.contains { $0.source == .app })
    }

    @Test
    func theEngineMicrophoneMarksAPauseFromItsOwnBuffers() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let live = LiveEvents(fixture.audio.stream)
        _ = try await fixture.start()
        try fixture.sendMic(Self.before)
        _ = await fixture.service.pauseRecording()
        try fixture.sendMic(Self.paused)
        #expect(await live.waitForMarkers(.mic, count: 1) == [1])
        _ = await fixture.service.resumeRecording()
        try fixture.sendMic(Self.after)
        _ = await fixture.service.pauseRecording()
        try fixture.sendMic(Self.paused)
        _ = await fixture.service.resumeRecording()
        try fixture.sendMic(Self.after)
        _ = await fixture.service.stopRecording()
        let events = await live.finished()
        #expect(sequence(events, .mic) == ["audio", "1", "audio", "2", "audio"])
    }
}
