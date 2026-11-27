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

    /// Holds one operation at a chosen suspension point until the test releases it.
    private final class Suspender: @unchecked Sendable {
        enum Point: Sendable { case captureStart, streamUpdate }
        private let lock = NSLock()
        private var armed: [Point] = []
        private var waiting: CheckedContinuation<Void, Never>?
        private var isHolding = false

        func arm(_ point: Point) { lock.withLock { armed = [point] } }
        /// Holds each point once, in this order.
        func arm(_ points: [Point]) { lock.withLock { armed = points } }

        func checkpoint(_ point: Point) async {
            let hold = lock.withLock {
                guard armed.first == point else { return false }
                armed.removeFirst()
                isHolding = true
                return true
            }
            guard hold else { return }
            await withCheckedContinuation { continuation in
                lock.withLock { waiting = continuation }
            }
        }

        /// Waits until an operation is held, or times out.
        func waitUntilHolding() async -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if lock.withLock({ isHolding && waiting != nil }) { return true }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return false
        }

        func release() {
            let continuation = lock.withLock {
                let continuation = waiting
                waiting = nil
                isHolding = false
                return continuation
            }
            continuation?.resume()
        }
    }

    /// Runs `onStop` while the stream stops, when a real stream still drains queued buffers.
    private final class StubStream: UnifiedCaptureStreaming, @unchecked Sendable {
        let onStop: @Sendable () -> Void
        let onUpdate: @Sendable (String?) async throws -> Void
        private let lock = NSLock()
        private var _isStopped = false
        var isStopped: Bool { lock.withLock { _isStopped } }
        init(onStop: @escaping @Sendable () -> Void, onUpdate: @escaping @Sendable (String?) async throws -> Void) {
            self.onStop = onStop
            self.onUpdate = onUpdate
        }
        func addStreamOutput(_: SCStreamOutput, type _: SCStreamOutputType, sampleHandlerQueue _: DispatchQueue?) throws {}
        func startCapture() async throws {}
        func stopCapture() async throws {
            onStop()
            lock.withLock { _isStopped = true }
        }
        func updateConfiguration(_ configuration: SCStreamConfiguration) async throws {
            try await onUpdate(configuration.microphoneCaptureDeviceID)
        }
    }

    private struct StubFailure: Error {}

    /// The sessions the service started, newest last.
    private final class Captures: @unchecked Sendable {
        private let lock = NSLock()
        private var _unified: [UnifiedCaptureSession] = []
        private var _streams: [StubStream] = []
        private var _onStop: (@Sendable () -> Void)?
        private var _failingStarts = 0
        private var _failingUpdates = 0
        private var _updatedMicDeviceUIDs: [String?] = []
        private var _refusedMicDeviceUIDs: Set<String> = []
        let suspender: Suspender
        init(suspender: Suspender) { self.suspender = suspender }
        var unified: [UnifiedCaptureSession] { lock.withLock { _unified } }
        var streams: [StubStream] { lock.withLock { _streams } }
        /// The microphone of every configuration update the streams accepted, oldest first.
        var updatedMicDeviceUIDs: [String?] { lock.withLock { _updatedMicDeviceUIDs } }
        /// Sessions still holding a running stream.
        var liveSessionCount: Int {
            unified.filter(\.isStreamLive).count
        }
        func setOnStop(_ body: @escaping @Sendable () -> Void) { lock.withLock { _onStop = body } }
        /// The next `count` starts throw.
        func failStarts(_ count: Int) { lock.withLock { _failingStarts = count } }
        /// The next `count` configuration updates throw.
        func failUpdates(_ count: Int) { lock.withLock { _failingUpdates = count } }
        /// Every update to `deviceUID` throws.
        func refuseUpdates(to deviceUID: String) { lock.withLock { _ = _refusedMicDeviceUIDs.insert(deviceUID) } }

        func start(_ start: RecordingService.CaptureSessionStart) async throws {
            await suspender.checkpoint(.captureStart)
            let stream = StubStream(
                onStop: { [weak self] in
                    guard let self else { return }
                    self.lock.withLock { self._onStop }?()
                },
                onUpdate: { [weak self] deviceUID in
                    guard let self else { return }
                    await self.suspender.checkpoint(.streamUpdate)
                    let fail = self.lock.withLock {
                        if let deviceUID, self._refusedMicDeviceUIDs.contains(deviceUID) { return true }
                        guard self._failingUpdates > 0 else { return false }
                        self._failingUpdates -= 1
                        return true
                    }
                    if fail { throw StubFailure() }
                    self.lock.withLock { self._updatedMicDeviceUIDs.append(deviceUID) }
                }
            )
            let fail = lock.withLock {
                guard _failingStarts > 0 else { return false }
                _failingStarts -= 1
                return true
            }
            switch start {
            case .unified(let session):
                lock.withLock { _unified.append(session) }

            }
            if fail { throw StubFailure() }
            lock.withLock { _streams.append(stream) }
            switch start {
            case .unified(let session):
                try await session.start(stream: stream)

            }
        }
    }

    private final class FakeHardware: AudioDeviceHardwareProviding, @unchecked Sendable {
        var devices: [(id: AudioDeviceID, uid: String)] = [(1, "device-a"), (2, "device-b"), (3, "device-c")]
        func unplug(_ uid: String) { devices.removeAll { $0.uid == uid } }
        /// A returning device gets a new id, as CoreAudio gives it.
        func plug(_ uid: String, id: AudioDeviceID) { devices.append((id, uid)) }
        func allDeviceIDs() throws -> [AudioDeviceID] { devices.map(\.id) }
        func inputChannelCount(deviceID _: AudioDeviceID) -> Int { 1 }
        func deviceUID(deviceID: AudioDeviceID) -> String? { devices.first { $0.id == deviceID }?.uid }
        func deviceName(deviceID: AudioDeviceID) -> String? { deviceUID(deviceID: deviceID).map { "Name of \($0)" } }
        func defaultInputDeviceID() -> AudioDeviceID? { devices.first?.id }
        func isAlive(deviceID _: AudioDeviceID) -> Bool { true }
        func isPrivateAggregate(deviceID _: AudioDeviceID) -> Bool { false }
    }

    private struct Fixture {
        let service: RecordingService
        let container: ModelContainer
        let workspace: Workspace
        let time: ManualTime
        let captures: Captures
        let hardware: FakeHardware
        let suspender: Suspender
        let audio = AsyncStream<LiveAudioChunk>.makeStream()
        let liveClock = LiveCaptureClock()

        func start(
            appProcessID: pid_t? = nil, recovery: Bool = true,
            micDeviceID: AudioDeviceID? = nil, preferredMic: String? = nil
        ) async throws -> UUID {
            try await service.startRecording(
                in: workspace,
                micDeviceID: micDeviceID,
                preferredMicDeviceUID: preferredMic,
                appProcessID: appProcessID,
                title: "Paused",
                liveAudioContinuation: audio.continuation,
                liveAudioClock: liveClock,
                audioSyncFlags: AudioSyncFlags(
                    isTimelineMixdownEnabled: true,

                    isCaptureHealthRecoveryEnabled: recovery
                )
            )
        }

        /// Waits until the app writer has written `frames`, or times out.
        func waitForAppFrames(_ frames: Int64) async {
            let deadline = Date().addingTimeInterval(5)
            while (await service.captureFrameCounts().app ?? 0) < frames, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        /// Feeds a 20 ms buffer captured now, and moves time past it.

        func sendMic(_ value: Float, rate: Double = 48_000) throws {
            let session = try #require(captures.unified.last)
            session.micHandler.processSampleBufferForTesting(
                try CaptureAudioGateTests.makeSampleBuffer(
                    Array(repeating: value, count: Int(rate / 50)), sampleRate: rate, hostTime: time.host
                )
            )
            time.advance(ms: 20)
        }

        /// Feeds 20 ms to both sources; the microphone at `micRate`.
        func sendUnified(_ value: Float, to session: UnifiedCaptureSession, micRate: Double = 48_000) throws {
            let buffer = try CaptureAudioGateTests.makeSampleBuffer(value20ms(value), sampleRate: 48_000, hostTime: time.host)
            let micBuffer = micRate == 48_000 ? buffer : try CaptureAudioGateTests.makeSampleBuffer(
                Array(repeating: value, count: Int(micRate / 50)), sampleRate: micRate, hostTime: time.host
            )
            session.micHandler.processSampleBufferForTesting(micBuffer)
            if session.hasAppSource { session.appHandler.processSampleBufferForTesting(buffer) }
            time.advance(ms: 20)
        }

        /// Feeds 20 ms of app audio only, as a stream whose microphone delivers nothing.
        func sendUnifiedAppOnly(_ value: Float, to session: UnifiedCaptureSession) throws {
            session.appHandler.processSampleBufferForTesting(
                try CaptureAudioGateTests.makeSampleBuffer(value20ms(value), sampleRate: 48_000, hostTime: time.host)
            )
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

    private func makeFixture(permissionError: RecordingError? = nil) async throws -> Fixture {
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
        let suspender = Suspender()
        let captures = Captures(suspender: suspender)
        let hardware = FakeHardware()
        let settings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: hardware,
            mixdownCoordinator: NoMixdown(),
            screenVideoMuxer: NoMux(),
            permissionChecker: { () async throws(RecordingError) in
                if let permissionError { throw permissionError }
            },
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            now: { time.date },
            hostNow: { time.host },
            captureSessionStarter: { try await captures.start($0) }
        )
        return Fixture(
            service: service, container: container, workspace: workspace, time: time, captures: captures,
            hardware: hardware, suspender: suspender
        )
    }

    @Test
    func micOnlyKeepsAppAbsentThroughRestartResumeAndFinalization() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let id = try await fixture.start(micDeviceID: 2, preferredMic: "device-b")
        let started = try fixture.session(id)
        #expect(started.appAudioURL == nil)
        #expect(fixture.captures.unified.count == 1)
        #expect(fixture.captures.unified.last?.hasAppSource == false)
        try fixture.sendMic(Self.before)
        #expect(await fixture.service.captureFrameCounts().app == nil)
        #expect(await fixture.service.captureArrivalCounts().app == nil)
        #expect(await fixture.service.restartAudioCaptureInPlace())
        #expect(fixture.captures.unified.last?.hasAppSource == false)
        #expect(await fixture.service.pauseRecording())
        try fixture.sendMic(Self.paused)
        #expect(await fixture.service.resumeRecording())
        try fixture.sendMic(Self.after)
        #expect(await fixture.service.stopRecording() == id)
        let saved = try fixture.session(id)
        #expect(saved.appAudioURL == nil)
        #expect(try samples(saved.micAudioURL) == run(Self.before, 1) + run(Self.after, 1))
        let micURL = URL(fileURLWithPath: saved.micAudioURL)
        #expect(!FileManager.default.fileExists(atPath: micURL.deletingLastPathComponent().appendingPathComponent("app.wav").path))
        let chunks = await fixture.chunks()
        #expect(chunks.allSatisfy { $0.source == .mic })
    }

    @Test
    func micOnlyStartVerificationRestartKeepsAppAbsent() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let id = try await fixture.start()
        #expect(await fixture.service.restartAudioCapture())
        #expect(fixture.captures.unified.count == 2)
        #expect(fixture.captures.unified.allSatisfy { !$0.hasAppSource })
        try fixture.sendMic(Self.before)
        _ = await fixture.service.stopRecording()
        #expect(try fixture.session(id).appAudioURL == nil)
    }

    enum StartFailure: CaseIterable, Sendable { case streamRefused, screenPermissionDenied, microphonePermissionDenied, noUsableMic }

    @Test(arguments: StartFailure.allCases)
    func micOnlyStartFailureHasApprovedMessageAndCreatesNoSession(kind: StartFailure) async throws {
        let permission: RecordingError? = switch kind {
        case .screenPermissionDenied: .failedToStart("Screen recording permission denied")
        case .microphonePermissionDenied: .microphoneDenied
        default: nil
        }
        let fixture = try await makeFixture(permissionError: permission)
        defer { fixture.remove() }
        if kind == .noUsableMic { fixture.hardware.devices = [] }
        if kind == .streamRefused { fixture.captures.failStarts(1) }
        do {
            _ = try await fixture.start()
            Issue.record("Expected recording start to fail")
        } catch {
            #expect(error.localizedDescription == "Recording failed to start: no audio.")
        }
        #expect(await fixture.service.isRecording() == false)
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<RecordingSession>()).isEmpty)
        #expect(fixture.captures.liveSessionCount == 0)
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

    @Test
    func levelsReadAsZeroWhilePaused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        func send(_ value: Float) throws {

                try fixture.sendUnified(value, to: try #require(fixture.captures.unified.last))

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
                if session.hasAppSource { session.appHandler.processSampleBufferForTesting(buffer) }
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

    // MARK: - Resume checks

    private static let stallThresholdMs: UInt64 = 3_100

    @Test(arguments: [true, false])
    func resumeRestartsADeadUnifiedCaptureInPlace(recovery: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, recovery: recovery)
        let original = try #require(fixture.captures.unified.last)
        try fixture.sendUnified(Self.before, to: original)
        _ = await fixture.service.pauseRecording()
        original.handleStreamStoppedForTesting(StubFailure())

        #expect(await fixture.service.resumeRecording())
        #expect(fixture.captures.unified.count == 2)
        let replacement = try #require(fixture.captures.unified.last)
        try fixture.sendUnified(Self.after, to: replacement)
        let id = try #require(await fixture.service.stopRecording())
        let session = try fixture.session(id)
        let expected = run(Self.before, 1) + run(Self.after, 1)
        #expect(try samples(session.micAudioURL) == expected)
        #expect(try samples(session.appAudioURL) == expected)
        #expect(session.captureInterruptionCount == 1)
    }

    @Test
    func resumeRestartsAUnifiedMicrophoneThatStoppedDelivering() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))
        _ = await fixture.service.pauseRecording()
        fixture.time.advance(ms: Self.stallThresholdMs)

        #expect(await fixture.service.resumeRecording())
        #expect(fixture.captures.unified.count == 2)
        _ = await fixture.service.stopRecording()
    }

    @Test
    func aRestartAtResumeOpensAWriterItsSourceNeverOpened() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        let original = try #require(fixture.captures.unified.last)
        // Only the microphone delivers before the pause.
        original.micHandler.processSampleBufferForTesting(
            try CaptureAudioGateTests.makeSampleBuffer(fixture.value20ms(Self.before), sampleRate: 48_000, hostTime: fixture.time.host)
        )
        fixture.time.advance(ms: 20)
        _ = await fixture.service.pauseRecording()
        original.handleStreamStoppedForTesting(StubFailure())

        #expect(await fixture.service.resumeRecording())
        try fixture.sendUnified(Self.after, to: try #require(fixture.captures.unified.last))
        let id = try #require(await fixture.service.stopRecording())
        let session = try fixture.session(id)
        #expect(try samples(session.micAudioURL) == run(Self.before, 1) + run(Self.after, 1))
        #expect(try samples(session.appAudioURL) == run(Self.after, 1))
    }

    @Test
    func unifiedAppAudioThatStopsDeliveringIsNotDeadAtResume() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        let session = try #require(fixture.captures.unified.last)
        try fixture.sendUnified(Self.before, to: session)
        _ = await fixture.service.pauseRecording()
        fixture.time.advance(ms: Self.stallThresholdMs)
        session.micHandler.processSampleBufferForTesting(
            try CaptureAudioGateTests.makeSampleBuffer(fixture.value20ms(Self.paused), sampleRate: 48_000, hostTime: fixture.time.host)
        )

        #expect(await fixture.service.resumeRecording())
        #expect(fixture.captures.unified.count == 1)
        _ = await fixture.service.stopRecording()
    }

    // MARK: - Failed resume

    @Test
    func aUnifiedCaptureThatCannotRestartFailsResumeAndRetryWorks() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        let original = try #require(fixture.captures.unified.last)
        try fixture.sendUnified(Self.before, to: original)
        _ = await fixture.service.pauseRecording()
        original.handleStreamStoppedForTesting(StubFailure())
        fixture.captures.failStarts(1)

        #expect(await fixture.service.resumeRecording() == false)
        #expect(await fixture.service.isPaused())
        #expect(await fixture.service.resumeRecording())
        try fixture.sendUnified(Self.after, to: try #require(fixture.captures.unified.last))
        let id = try #require(await fixture.service.stopRecording())
        #expect(try samples(fixture.session(id).micAudioURL) == run(Self.before, 1) + run(Self.after, 1))
    }

    enum Operation: CaseIterable, Sendable {
        case unifiedRetarget, unifiedHardwareChange, restartInPlace
        case unifiedResume, unifiedRemoval, unifiedReturn
    }

    enum Interleaving: CaseIterable, Sendable { case pause, resume, stop }

    private func prepare(_ operation: Operation, paused: Bool, _ fixture: Fixture) async throws {
        var micDeviceID: AudioDeviceID?
        var preferredMic: String?
        if operation == .unifiedRemoval { micDeviceID = 2; preferredMic = "device-b" }
        if operation == .unifiedReturn { fixture.hardware.unplug("device-b"); preferredMic = "device-b" }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: micDeviceID, preferredMic: preferredMic)
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))
        if operation == .unifiedHardwareChange {
            fixture.captures.failUpdates(1)
            await fixture.service.retargetMic(desiredDeviceUID: "device-b")
        }
        if paused {
            _ = await fixture.service.pauseRecording()
            try fixture.sendUnified(Self.paused, to: try #require(fixture.captures.unified.last))
        }
    }

    private func run(_ operation: Operation, _ fixture: Fixture) -> Task<Void, Never> {
        let service = fixture.service
        switch operation {
        case .unifiedRetarget, .unifiedHardwareChange: fixture.suspender.arm(.streamUpdate)
        case .restartInPlace: fixture.suspender.arm(.captureStart)
        case .unifiedResume:
            fixture.captures.unified.last?.handleStreamStoppedForTesting(StubFailure())
            fixture.suspender.arm(.captureStart)
        case .unifiedRemoval:
            fixture.hardware.unplug("device-b")
            fixture.suspender.arm(.streamUpdate)
        case .unifiedReturn:
            fixture.hardware.plug("device-b", id: 4)
            fixture.suspender.arm(.streamUpdate)
        }
        return Task {
            switch operation {
            case .unifiedRetarget: await service.retargetMic(desiredDeviceUID: "device-b")
            case .unifiedHardwareChange, .unifiedRemoval, .unifiedReturn: await service.simulateHardwareChangeForTesting()
            case .restartInPlace: _ = await service.restartAudioCaptureInPlace()
            case .unifiedResume: _ = await service.resumeRecording()
            }
        }
    }

    @Test(arguments: Operation.allCases, Interleaving.allCases)
    func aSuspendedOperationStaysSafeAroundPauseResumeAndStop(
        operation: Operation, interleaving: Interleaving
    ) async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let startsPaused = operation == .unifiedResume || interleaving == .resume
        try await prepare(operation, paused: startsPaused, fixture)

        let task = run(operation, fixture)
        #expect(await fixture.suspender.waitUntilHolding())
        let service = fixture.service
        let interleaved = Task { () -> UUID? in
            switch interleaving {
            case .pause: _ = await service.pauseRecording()
            case .resume: _ = await service.resumeRecording()
            case .stop: return await service.stopRecording()
            }
            return nil
        }
        // Let the interleaved call run as far as it goes before the operation continues.
        try await Task.sleep(for: .milliseconds(50))
        fixture.suspender.release()
        await task.value
        let stoppedID = await interleaved.value

        switch interleaving {
        case .stop:
            #expect(stoppedID != nil)
            #expect(await fixture.service.isRecording() == false)
            #expect(fixture.captures.liveSessionCount == 0)
        case .pause, .resume:
            #expect(await fixture.service.isPaused() == (interleaving == .pause))
            if [.unifiedRetarget, .unifiedHardwareChange, .unifiedReturn].contains(operation) {
                #expect(fixture.captures.unified.last?.currentMicDeviceUID == "device-b")
            }
            if operation == .unifiedRemoval {
                #expect(fixture.captures.unified.last?.currentMicDeviceUID == nil)
                #expect(fixture.captures.updatedMicDeviceUIDs == [nil])
            }
            if [.unifiedRemoval, .unifiedReturn].contains(operation) { #expect(fixture.captures.unified.count == 1) }
            if interleaving == .pause {
                try fixture.sendUnified(Self.paused, to: try #require(fixture.captures.unified.last))
                _ = await fixture.service.resumeRecording()
            }
            try fixture.sendUnified(Self.after, to: try #require(fixture.captures.unified.last))
            let id = try #require(await fixture.service.stopRecording())
            let session = try fixture.session(id)
            let expected = run(Self.before, 1) + run(Self.after, 1)
            #expect(try samples(session.micAudioURL) == expected)
            #expect(try samples(session.appAudioURL) == expected)
            #expect(fixture.captures.liveSessionCount == 0)
        }
    }

    // MARK: - Operations suspended

    @Test
    func aUnifiedRetargetEndsOnTheNewestRequestedDevice() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        fixture.suspender.arm(.streamUpdate)
        let service = fixture.service
        let first = Task { await service.retargetMic(desiredDeviceUID: "device-b") }
        #expect(await fixture.suspender.waitUntilHolding())
        let second = Task { await service.retargetMic(desiredDeviceUID: "device-c") }
        try await Task.sleep(for: .milliseconds(50))
        fixture.suspender.release()
        await first.value
        await second.value

        #expect(fixture.captures.unified.last?.currentMicDeviceUID == "device-c")
        _ = await service.stopRecording()
    }

    @Test
    func concurrentRestartsInPlaceShareOneReplacement() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))
        fixture.suspender.arm(.captureStart)
        let service = fixture.service
        let first = Task { await service.restartAudioCaptureInPlace() }
        #expect(await fixture.suspender.waitUntilHolding())
        let second = Task { await service.restartAudioCaptureInPlace() }
        try await Task.sleep(for: .milliseconds(50))
        fixture.suspender.release()

        #expect(await first.value)
        #expect(await second.value)
        #expect(fixture.captures.unified.count == 2)
        let id = try #require(await service.stopRecording())
        #expect(try fixture.session(id).captureInterruptionCount == 1)
    }

    // MARK: - Failures resume handled

    /// Waits until the service has counted `count` stream failures, which arrive through a task.
    private func waitForStreamFailures(_ count: Int, on service: RecordingService) async {
        let deadline = Date().addingTimeInterval(5)
        while await service.captureHealthSnapshot().streamFailureCount < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test
    func aFailureResumeHandledIsAcknowledgedAndALaterOneIsNot() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        let original = try #require(fixture.captures.unified.last)
        try fixture.sendUnified(Self.before, to: original)
        _ = await fixture.service.pauseRecording()
        original.handleStreamStoppedForTesting(StubFailure())
        await waitForStreamFailures(1, on: fixture.service)

        #expect(await fixture.service.resumeRecording())
        let afterResume = await fixture.service.captureHealthSnapshot()
        #expect(afterResume.streamFailureCount == 1)
        #expect(afterResume.handledStreamFailureCount == 1)
        #expect(await fixture.service.consumePendingError() == nil)

        try #require(fixture.captures.unified.last).handleStreamStoppedForTesting(StubFailure())
        await waitForStreamFailures(2, on: fixture.service)
        let later = await fixture.service.captureHealthSnapshot()
        #expect(later.handledStreamFailureCount == 1)
        #expect(await fixture.service.consumePendingError() != nil)
        _ = await fixture.service.stopRecording()
    }

    @Test
    func aFailureDuringARecordingThatIsNotPausedIsNotAcknowledged() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        try #require(fixture.captures.unified.last).handleStreamStoppedForTesting(StubFailure())
        await waitForStreamFailures(1, on: fixture.service)

        // Not paused: the resume changes nothing and handles nothing.
        #expect(await fixture.service.resumeRecording())
        #expect(await fixture.service.captureHealthSnapshot().handledStreamFailureCount == 0)
        _ = await fixture.service.stopRecording()
    }

    // MARK: - Microphone removed and returned

    @Test
    func unifiedCaptureMovesToTheDefaultWhenItsMicIsRemovedAndBackWhenItReturns() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        let session = try #require(fixture.captures.unified.last)
        #expect(session.currentMicDeviceUID == "device-b")
        try fixture.sendUnified(Self.before, to: session)

        fixture.hardware.unplug("device-b")
        await fixture.service.simulateHardwareChangeForTesting()
        #expect(fixture.captures.updatedMicDeviceUIDs == [nil])
        try fixture.sendUnified(Self.after, to: session)

        fixture.hardware.plug("device-b", id: 4)
        await fixture.service.simulateHardwareChangeForTesting()
        #expect(fixture.captures.updatedMicDeviceUIDs == [nil, "device-b"])
        try fixture.sendUnified(Self.before, to: session)

        #expect(fixture.captures.unified.count == 1)
        let id = try #require(await fixture.service.stopRecording())
        let expected = run(Self.before, 1) + run(Self.after, 1) + run(Self.before, 1)
        #expect(try samples(fixture.session(id).micAudioURL) == expected)
        #expect(try samples(fixture.session(id).appAudioURL) == expected)
    }

    /// Removed and back under the same UID before the fallback was applied: the stream still names
    /// the UID and gets nothing from it until it is moved away and back.
    @Test
    func aUnifiedMicThatReturnsUnderTheSameUIDIsMovedAwayAndBack() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        let session = try #require(fixture.captures.unified.last)

        fixture.hardware.unplug("device-b")
        fixture.hardware.plug("device-b", id: 4)
        await fixture.service.simulateHardwareChangeForTesting()

        #expect(fixture.captures.updatedMicDeviceUIDs == [nil, "device-b"])
        #expect(session.currentMicDeviceUID == "device-b")
        await fixture.service.simulateHardwareChangeForTesting()
        #expect(fixture.captures.updatedMicDeviceUIDs == [nil, "device-b"])
        _ = await fixture.service.stopRecording()
    }

    @Test
    func removalsAndSwitchesAreReportedToCaptureHealthButItsOwnRestartsAreNot() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(
            appProcessID: 1, micDeviceID: 2, preferredMic: "device-b"
        )
        let atStart = await fixture.service.captureHealthSnapshot().lastMicTransition

        fixture.hardware.unplug("device-b")
        await fixture.service.simulateHardwareChangeForTesting()
        let afterRemoval = try #require(await fixture.service.captureHealthSnapshot().lastMicTransition)
        #expect(afterRemoval.number > (atStart?.number ?? 0))

        #expect(await fixture.service.restartAudioCaptureInPlace())
        #expect(await fixture.service.captureHealthSnapshot().lastMicTransition == afterRemoval)

        fixture.hardware.plug("device-b", id: 4)
        await fixture.service.simulateHardwareChangeForTesting()
        let afterReturn = try #require(await fixture.service.captureHealthSnapshot().lastMicTransition)
        #expect(afterReturn.number > afterRemoval.number)
        _ = await fixture.service.stopRecording()
    }

    /// Polls `condition` for up to 5 s.
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    @Test
    func aUnifiedRestartTargetsByTheRuleInsteadOfTheDeviceItReplaces() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))

        // No hardware event is handled: the restart alone must not target the absent device.
        fixture.hardware.unplug("device-b")
        #expect(await fixture.service.restartAudioCaptureInPlace())
        #expect(fixture.captures.unified.last?.currentMicDeviceUID == nil)
        try fixture.sendUnified(Self.after, to: try #require(fixture.captures.unified.last))

        fixture.hardware.plug("device-b", id: 4)
        #expect(await fixture.service.restartAudioCaptureInPlace())
        #expect(fixture.captures.unified.last?.currentMicDeviceUID == "device-b")
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))

        #expect(fixture.captures.updatedMicDeviceUIDs.isEmpty)
        let id = try #require(await fixture.service.stopRecording())
        let expected = run(Self.before, 1) + run(Self.after, 1) + run(Self.before, 1)
        #expect(try samples(fixture.session(id).micAudioURL) == expected)
    }

    // MARK: Two transitions overlapping

    enum Transition: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case removal, returnUnderNewID, restart, retargetToC
        var testDescription: String { rawValue }
    }

    /// Requests `transition` on a unified recording; held at its suspension point when armed.
    private func request(_ transition: Transition, _ fixture: Fixture, hold: Bool) -> Task<Void, Never> {
        let service = fixture.service
        switch transition {
        case .removal:
            fixture.hardware.unplug("device-b")
            if hold { fixture.suspender.arm(.streamUpdate) }
            return Task { await service.simulateHardwareChangeForTesting() }
        case .returnUnderNewID:
            fixture.hardware.plug("device-b", id: 4)
            if hold { fixture.suspender.arm(.streamUpdate) }
            return Task { await service.simulateHardwareChangeForTesting() }
        case .restart:
            if hold { fixture.suspender.arm(.captureStart) }
            return Task { _ = await service.restartAudioCaptureInPlace() }
        case .retargetToC:
            if hold { fixture.suspender.arm(.streamUpdate) }
            return Task { await service.retargetMic(desiredDeviceUID: "device-c") }
        }
    }

    /// The device the unified stream must end on after both transitions, by the target rule.
    private func expectedDevice(after transitions: [Transition]) -> String? {
        var preferred = "device-b"
        var present: Set<String> = ["device-a", "device-b", "device-c"]
        for transition in transitions {
            switch transition {
            case .removal: present.remove("device-b")
            case .returnUnderNewID: present.insert("device-b")
            case .restart: break
            case .retargetToC: preferred = "device-c"
            }
        }
        if present.contains(preferred) { return preferred }
        // The recording started on device-b, the fallback while it is usable.
        return present.contains("device-b") ? "device-b" : nil
    }

    @Test(arguments: [
        (Transition.removal, Transition.restart), (.restart, .removal),
        (.removal, .retargetToC), (.retargetToC, .removal),
        (.removal, .returnUnderNewID), (.restart, .retargetToC), (.retargetToC, .restart),
    ])
    func twoOverlappingUnifiedTransitionsEndOnTheTargetRulesDevice(first: Transition, second: Transition) async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))

        let held = request(first, fixture, hold: true)
        #expect(await fixture.suspender.waitUntilHolding())
        let queued = request(second, fixture, hold: false)
        try await Task.sleep(for: .milliseconds(50))
        fixture.suspender.release()
        await held.value
        await queued.value

        let device = expectedDevice(after: [first, second])
        let session = try #require(fixture.captures.unified.last)
        #expect(session.currentMicDeviceUID == device)
        #expect(await fixture.service.micCaptureTarget() == MicCaptureTarget(deviceUID: device))
        #expect(fixture.captures.liveSessionCount == 1)
        try fixture.sendUnified(Self.after, to: session)
        let id = try #require(await fixture.service.stopRecording())
        let expected = run(Self.before, 1) + run(Self.after, 1)
        #expect(try samples(fixture.session(id).micAudioURL) == expected)
        #expect(try samples(fixture.session(id).appAudioURL) == expected)
    }

    @Test
    func anUpdateThatIsNoLongerTheTargetIsNotReportedAsCaptured() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        fixture.captures.refuseUpdates(to: "device-c")

        let removal = request(.removal, fixture, hold: true)
        #expect(await fixture.suspender.waitUntilHolding())
        let retarget = request(.retargetToC, fixture, hold: false)
        try await Task.sleep(for: .milliseconds(50))
        fixture.suspender.release()
        await removal.value
        await retarget.value

        // The stream is on the default, which was no longer the target when its update finished.
        #expect(fixture.captures.updatedMicDeviceUIDs == [nil])
        #expect(await fixture.service.micCaptureTarget()?.deviceUID == "device-b")
        _ = await fixture.service.stopRecording()
    }

    // MARK: Pause

    @Test
    func aRemovalDuringAPauseIsAppliedAtOnceAndWritesNothingUntilResume() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(
            appProcessID: 1, micDeviceID: 2, preferredMic: "device-b"
        )
        func send(_ value: Float) throws {

                try fixture.sendUnified(value, to: try #require(fixture.captures.unified.last))

        }
        try send(Self.before)
        _ = await fixture.service.pauseRecording()
        try send(Self.paused)

        fixture.hardware.unplug("device-b")
        await fixture.service.simulateHardwareChangeForTesting()

            #expect(fixture.captures.updatedMicDeviceUIDs == [nil])

        #expect(await fixture.service.isPaused())
        try send(Self.paused)

        #expect(await fixture.service.resumeRecording())
        try send(Self.after)
        let id = try #require(await fixture.service.stopRecording())
        #expect(try samples(fixture.session(id).micAudioURL) == run(Self.before, 1) + run(Self.after, 1))
    }

    @Test
    func aSwitchRunningAtResumeCompletesBeforeTheClocksReopen() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(
            appProcessID: 1, micDeviceID: 2, preferredMic: "device-b"
        )
        _ = await fixture.service.pauseRecording()
        let service = fixture.service
        fixture.hardware.unplug("device-b")
        fixture.suspender.arm(.streamUpdate)
        let removal = Task { await service.simulateHardwareChangeForTesting() }
        #expect(await fixture.suspender.waitUntilHolding())

        let resume = Task { await service.resumeRecording() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.isPaused())
        fixture.suspender.release()
        #expect(await resume.value)
        await removal.value

        #expect(await service.isPaused() == false)

            #expect(fixture.captures.unified.last?.currentMicDeviceUID == nil)

        _ = await service.stopRecording()
    }

    @Test
    func aRemovalDuringTheResumesOwnRestartIsAppliedBeforeTheClocksReopen() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))
        _ = await fixture.service.pauseRecording()
        try #require(fixture.captures.unified.last).handleStreamStoppedForTesting(StubFailure())
        let service = fixture.service

        fixture.suspender.arm([.captureStart, .streamUpdate])
        let resume = Task { await service.resumeRecording() }
        #expect(await fixture.suspender.waitUntilHolding())
        fixture.hardware.unplug("device-b")
        let removal = Task { await service.simulateHardwareChangeForTesting() }
        try await Task.sleep(for: .milliseconds(50))
        fixture.suspender.release()
        // The restart is done; the removal's update is held, and the clocks stay closed.
        #expect(await fixture.suspender.waitUntilHolding())
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.isPaused())
        fixture.suspender.release()
        #expect(await resume.value)

        // The replacement started on device-b; the removal queued behind it moved it before the
        // resume returned.
        let session = try #require(fixture.captures.unified.last)
        #expect(session.currentMicDeviceUID == nil)
        await removal.value
        try fixture.sendUnified(Self.after, to: session)
        let id = try #require(await service.stopRecording())
        #expect(try samples(fixture.session(id).micAudioURL) == run(Self.before, 1) + run(Self.after, 1))
    }

    @Test
    func aRejectedUnifiedFallbackFailsResumeWhenTheRestartFailsToo() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))
        _ = await fixture.service.pauseRecording()

        fixture.captures.failUpdates(1)
        fixture.hardware.unplug("device-b")
        await fixture.service.simulateHardwareChangeForTesting()
        #expect(fixture.captures.unified.last?.currentMicDeviceUID == "device-b")

        fixture.captures.failStarts(1)
        #expect(await fixture.service.resumeRecording() == false)
        #expect(await fixture.service.isPaused())

        #expect(await fixture.service.resumeRecording())
        let session = try #require(fixture.captures.unified.last)
        #expect(session.currentMicDeviceUID == nil)
        try fixture.sendUnified(Self.after, to: session)
        let id = try #require(await fixture.service.stopRecording())
        #expect(try samples(fixture.session(id).micAudioURL) == run(Self.before, 1) + run(Self.after, 1))
    }

    // MARK: Start and stop

    @Test
    func aRemovalWhileUnifiedCaptureStartsIsAppliedOnceItRuns() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        fixture.suspender.arm(.captureStart)
        let start = Task { try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b") }
        #expect(await fixture.suspender.waitUntilHolding())
        fixture.hardware.unplug("device-b")
        fixture.suspender.release()
        _ = try await start.value

        #expect(fixture.captures.updatedMicDeviceUIDs == [nil])
        #expect(await fixture.service.micCaptureTarget() == MicCaptureTarget(deviceUID: nil))
        _ = await fixture.service.stopRecording()
    }

    @Test
    func aHardwareChangeAfterStopDoesNothing() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        _ = await fixture.service.stopRecording()
        fixture.hardware.unplug("device-b")
        await fixture.service.simulateHardwareChangeForTesting()
        #expect(fixture.captures.updatedMicDeviceUIDs.isEmpty)
        #expect(fixture.captures.unified.count == 1)
    }

    // MARK: Failures

    @Test
    func aUnifiedFallbackThatDeliversNoMicBuffersKeepsRecordingAndReportsNoFirstBuffer() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        let session = try #require(fixture.captures.unified.last)
        try fixture.sendUnified(Self.before, to: session)

        fixture.hardware.unplug("device-b")
        await fixture.service.simulateHardwareChangeForTesting()
        #expect(fixture.captures.updatedMicDeviceUIDs == [nil])
        try fixture.sendUnifiedAppOnly(Self.after, to: session)

        #expect(await fixture.service.micCaptureTarget() == MicCaptureTarget(deviceUID: nil))
        #expect(await fixture.service.isRecording())
        #expect(fixture.captures.unified.count == 1)
        await fixture.waitForAppFrames(1_920)
        let id = try #require(await fixture.service.stopRecording())
        #expect(try samples(fixture.session(id).micAudioURL) == run(Self.before, 1))
        #expect(try samples(fixture.session(id).appAudioURL) == run(Self.before, 1) + run(Self.after, 1))
    }

    @Test
    func aRejectedUnifiedFallbackIsLeftToARestartWhichTargetsTheDefault() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))

        fixture.captures.failUpdates(1)
        fixture.hardware.unplug("device-b")
        await fixture.service.simulateHardwareChangeForTesting()
        #expect(fixture.captures.updatedMicDeviceUIDs.isEmpty)
        #expect(fixture.captures.unified.last?.currentMicDeviceUID == "device-b")
        #expect(await fixture.service.isRecording())

        // A failed restart keeps what was captured; the next one lands on the default.
        fixture.captures.failStarts(1)
        #expect(await fixture.service.restartAudioCaptureInPlace() == false)
        #expect(await fixture.service.restartAudioCaptureInPlace())
        let session = try #require(fixture.captures.unified.last)
        #expect(session.currentMicDeviceUID == nil)
        try fixture.sendUnified(Self.after, to: session)
        let id = try #require(await fixture.service.stopRecording())
        #expect(try samples(fixture.session(id).micAudioURL) == run(Self.before, 1) + run(Self.after, 1))
    }

    // MARK: Stale stream callbacks

    @Test
    func aDelayedCallbackFromAReplacedStreamIsIgnored() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1)
        let original = try #require(fixture.captures.unified.last)
        #expect(await fixture.service.restartAudioCaptureInPlace())

        original.handleStreamStoppedForTesting(StubFailure())
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fixture.service.captureHealthSnapshot().streamFailureCount == 0)
        #expect(await fixture.service.consumePendingError() == nil)

        try #require(fixture.captures.unified.last).handleStreamStoppedForTesting(StubFailure())
        await waitForStreamFailures(1, on: fixture.service)
        #expect(await fixture.service.captureHealthSnapshot().streamFailureCount == 1)
        _ = await fixture.service.stopRecording()
    }

    @Test
    func aDelayedCallbackFromThePreviousRecordingIsIgnored() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, )
        let previousUnified = fixture.captures.unified.last
        _ = await fixture.service.stopRecording()
        _ = try await fixture.start(appProcessID: 1, )

        previousUnified?.handleStreamStoppedForTesting(StubFailure())
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fixture.service.captureHealthSnapshot().streamFailureCount == 0)
        _ = await fixture.service.stopRecording()
    }

    // MARK: Sample rate across a switch

    @Test
    func aDefaultAtAnotherSampleRateIsWrittenAtItsRealLength() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        func send(_ value: Float, rate: Double) throws {

                try fixture.sendUnified(value, to: try #require(fixture.captures.unified.last), micRate: rate)

        }
        for _ in 0..<10 { try send(Self.before, rate: 48_000) }
        fixture.hardware.unplug("device-b")
        await fixture.service.simulateHardwareChangeForTesting()
        for _ in 0..<10 { try send(Self.after, rate: 24_000) }

        let id = try #require(await fixture.service.stopRecording())
        let written = try samples(fixture.session(id).micAudioURL)
        #expect(Array(written.prefix(9_600)) == run(Self.before, 10))
        let rest = written.dropFirst(9_600)
        // 0.2 s at 48 kHz, give or take one buffer of converter latency; never doubled.
        #expect(abs(rest.count - 9_600) <= 960)
        #expect(rest.filter { abs($0 - Self.after) < 0.01 }.count >= 8_000)
        #expect(!rest.contains { abs($0 - Self.before) < 0.01 })
    }

    // MARK: What capture is aimed at (for reporting)

    @Test
    func theCaptureTargetFollowsTheSwitchAndItsFirstBuffer() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        func send(_ value: Float) throws {

                try fixture.sendUnified(value, to: try #require(fixture.captures.unified.last))

        }
        let service = fixture.service
        #expect(await service.micCaptureTarget() == MicCaptureTarget(deviceUID: "device-b"))
        let firstAt = fixture.time.host
        try send(Self.before)
        #expect(await eventually { await service.micCaptureTarget()?.firstBufferHostTime == firstAt })

        fixture.hardware.unplug("device-b")
        await service.simulateHardwareChangeForTesting()
        #expect(await service.micCaptureTarget() == MicCaptureTarget(deviceUID: nil))
        let fallbackAt = fixture.time.host
        try send(Self.after)
        #expect(await eventually {
            await service.micCaptureTarget() == MicCaptureTarget(deviceUID: nil, firstBufferHostTime: fallbackAt)
        })

        fixture.hardware.plug("device-b", id: 4)
        await service.simulateHardwareChangeForTesting()
        #expect(await service.micCaptureTarget() == MicCaptureTarget(deviceUID: "device-b"))
        _ = await service.stopRecording()
        #expect(await service.micCaptureTarget() == nil)
    }

    // MARK: Captured microphone (requirement 21)

    @Test
    func theFirstBufferMarksTheStartDeviceAsCaptured() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        let service = fixture.service
        #expect(await service.capturedMicrophone() == .switching)


            try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))


        #expect(await eventually {
            await service.capturedMicrophone()
                == .capturing(CapturedMicDevice(uid: "device-b", name: "Name of device-b", isSystemDefault: false))
        })
        _ = await service.stopRecording()
        #expect(await service.capturedMicrophone() == nil)
    }

    @Test
    func aRemovedMicIsNotReportedWhileTheUpdateRuns() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        let service = fixture.service
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))
        #expect(await eventually { await service.capturedMicrophone() != .switching })

        let removal = request(.removal, fixture, hold: true)
        #expect(await fixture.suspender.waitUntilHolding())
        #expect(await service.capturedMicrophone() == .switching)
        fixture.suspender.release()
        await removal.value
        _ = await service.stopRecording()
    }

    @Test
    func aRejectedUpdateKeepsReportingTheDeviceStillCaptured() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        let service = fixture.service
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))
        let deviceB = CapturedMicrophone.capturing(
            CapturedMicDevice(uid: "device-b", name: "Name of device-b", isSystemDefault: false)
        )
        #expect(await eventually { await service.capturedMicrophone() == deviceB })

        fixture.captures.refuseUpdates(to: "device-c")
        await service.retargetMic(desiredDeviceUID: "device-c")

        #expect(fixture.captures.updatedMicDeviceUIDs.isEmpty)
        #expect(await service.capturedMicrophone() == deviceB)
        _ = await service.stopRecording()
    }

    @Test
    func anUpdateLeftOffTheTargetIsReportedAsSwitching() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        let service = fixture.service
        try fixture.sendUnified(Self.before, to: try #require(fixture.captures.unified.last))
        #expect(await eventually { await service.capturedMicrophone() != .switching })
        fixture.captures.refuseUpdates(to: "device-c")

        let removal = request(.removal, fixture, hold: true)
        #expect(await fixture.suspender.waitUntilHolding())
        let retarget = request(.retargetToC, fixture, hold: false)
        try await Task.sleep(for: .milliseconds(50))
        fixture.suspender.release()
        await removal.value
        await retarget.value
        try fixture.sendUnified(Self.after, to: try #require(fixture.captures.unified.last))
        try await Task.sleep(for: .milliseconds(50))

        // The stream is on the default, an update no longer current when it finished (requirement 8).
        #expect(fixture.captures.updatedMicDeviceUIDs == [nil])
        #expect(await service.capturedMicrophone() == .switching)
        _ = await service.stopRecording()
    }

    private static let capturingB = CapturedMicrophone.capturing(
        CapturedMicDevice(uid: "device-b", name: "Name of device-b", isSystemDefault: false)
    )
    /// The fake's default input is its first device.
    private static let capturingDefaultA = CapturedMicrophone.capturing(
        CapturedMicDevice(uid: "device-a", name: "Name of device-a", isSystemDefault: true)
    )

    @Test
    func aRemovalReportsTheDefaultFromItsFirstBufferAndAReturnReportsTheMicAgain() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        func send(_ value: Float) throws {

                try fixture.sendUnified(value, to: try #require(fixture.captures.unified.last))

        }
        let service = fixture.service
        try send(Self.before)
        #expect(await eventually { await service.capturedMicrophone() == Self.capturingB })

        fixture.hardware.unplug("device-b")
        await service.simulateHardwareChangeForTesting()
        #expect(await service.capturedMicrophone() == .switching)
        try send(Self.after)
        #expect(await eventually { await service.capturedMicrophone() == Self.capturingDefaultA })

        fixture.hardware.plug("device-b", id: 4)
        await service.simulateHardwareChangeForTesting()
        #expect(await service.capturedMicrophone() == .switching)
        try send(Self.before)
        #expect(await eventually { await service.capturedMicrophone() == Self.capturingB })
        _ = await service.stopRecording()
    }

    @Test
    func aPauseKeepsReportingTheMicCapturedWhenItBegan() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start(appProcessID: 1, micDeviceID: 2, preferredMic: "device-b")
        func send(_ value: Float) throws {

                try fixture.sendUnified(value, to: try #require(fixture.captures.unified.last))

        }
        let service = fixture.service
        try send(Self.before)
        #expect(await eventually { await service.capturedMicrophone() == Self.capturingB })

        _ = await service.pauseRecording()
        fixture.hardware.unplug("device-b")
        await service.simulateHardwareChangeForTesting()
        #expect(await service.capturedMicrophone() == Self.capturingB)
        try send(Self.paused)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.capturedMicrophone() == Self.capturingB)

        #expect(await service.resumeRecording())
        try send(Self.after)
        #expect(await eventually { await service.capturedMicrophone() == Self.capturingDefaultA })
        _ = await service.stopRecording()
    }

    @Test
    func aPauseBeforeAnyMicAudioDoesNotReportThePreviousRecordingsMic() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        let service = fixture.service
        _ = try await fixture.start(micDeviceID: 2, preferredMic: "device-b")
        try fixture.sendMic(Self.before)
        #expect(await eventually { await service.capturedMicrophone() == Self.capturingB })
        _ = await service.stopRecording()

        _ = try await fixture.start(micDeviceID: 3, preferredMic: "device-c")
        _ = await service.pauseRecording()

        #expect(await service.capturedMicrophone() == .switching)
        _ = await service.stopRecording()
    }

    // MARK: - Dictation

    @Test
    @MainActor
    func dictationStaysBlockedWhilePaused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.remove() }
        _ = try await fixture.start()
        #expect(await fixture.service.pauseRecording())
        let capture = CountingDictationCapture()
        let dictation = DictationService(recordingService: fixture.service, captureSession: capture, insertText: { _ in .insertedDirectly })

        await dictation.start(deviceID: nil)

        #expect(dictation.state == .idle)
        #expect(await capture.startCalls == 0)
        _ = await fixture.service.stopRecording()
    }

    private actor CountingDictationCapture: DictationCapturing {
        private(set) var startCalls = 0
        func start(deviceID _: AudioDeviceID?) async throws -> AsyncThrowingStream<[Float], Error> {
            startCalls += 1
            return AsyncThrowingStream { $0.finish() }
        }
        func stop() async {}
        func setLevelHandler(_: @escaping @Sendable (Float) -> Void) async {}
    }
}
