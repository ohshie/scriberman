import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing
@testable import Scriberman

/// Stand-in for `SCStream`, which cannot be constructed in tests: it needs live
/// `SCShareableContent`, a capturable window, and Screen Recording + Microphone TCC grants.
private final class StubCaptureStream: UnifiedCaptureStreaming, @unchecked Sendable {
    var outputTypes: [SCStreamOutputType] = []
    var updateError: Error?
    private(set) var updateCallCount = 0
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var addOutputCallCount = 0
    /// Mic device identifiers seen by each `updateConfiguration` call, in order.
    private(set) var appliedMicDeviceUIDs: [String?] = []

    func addStreamOutput(
        _: SCStreamOutput,
        type: SCStreamOutputType,
        sampleHandlerQueue _: DispatchQueue?
    ) throws {
        outputTypes.append(type)
        addOutputCallCount += 1
    }

    func startCapture() async throws {
        startCallCount += 1
    }

    func stopCapture() async throws {
        stopCallCount += 1
    }

    func updateConfiguration(_ configuration: SCStreamConfiguration) async throws {
        updateCallCount += 1
        appliedMicDeviceUIDs.append(configuration.microphoneCaptureDeviceID)
        if let updateError {
            throw updateError
        }
    }
}

private struct StubUpdateError: Error {}

struct UnifiedCaptureSessionTests {
    private func makeSession(micDeviceUID: String?) -> (UnifiedCaptureSession, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = UnifiedCaptureSession(
            micFileURL: root.appendingPathComponent("mic.wav"),
            appFileURL: root.appendingPathComponent("app.wav"),
            processID: 1234,
            micDeviceUID: micDeviceUID
        )
        return (session, root)
    }

    @Test
    func micOnlyRegistersOnlyMicrophoneAndKeepsAppOutputAbsent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UnifiedCaptureSession(
            micFileURL: root.appendingPathComponent("mic.wav"),
            appFileURL: nil, processID: nil, micDeviceUID: "device-a"
        )
        let stream = StubCaptureStream()
        try session.addOutputs(to: stream)
        #expect(stream.outputTypes == [.microphone])
        let config = session.configuration
        #expect(!config.capturesAudio)
        #expect(config.captureMicrophone)
        #expect(config.microphoneCaptureDeviceID == "device-a")
        #expect(config.sampleRate == 48_000)
        #expect(config.channelCount == 2)
        #expect(config.width == 2 && config.height == 2)
        #expect(config.minimumFrameInterval == CMTime(value: 1, timescale: 1))
        #expect(config.queueDepth == 3)
        #expect(!session.hasAppSource)
        #expect(!session.preparedStreamers.app)
        await session.stop()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("app.wav").path))
    }

    @Test
    func testInitialMicDeviceUIDReflectsRequestedDevice() {
        let (session, _) = makeSession(micDeviceUID: "BuiltInMicrophoneDevice")
        #expect(session.currentMicDeviceUID == "BuiltInMicrophoneDevice")
    }

    @Test
    func testRetargetAppliesNewDeviceToLiveStreamWithoutRestarting() async {
        let (session, _) = makeSession(micDeviceUID: "device-a")
        let stream = StubCaptureStream()
        session.attachStreamForTesting(stream)

        let didRetarget = await session.retargetMic(deviceUID: "device-b")

        #expect(didRetarget)
        #expect(stream.updateCallCount == 1)
        #expect(stream.appliedMicDeviceUIDs == ["device-b"])
        #expect(session.currentMicDeviceUID == "device-b")
        // The stream must not be torn down or rebuilt to change the microphone.
        #expect(stream.stopCallCount == 0)
        #expect(stream.startCallCount == 0)
        #expect(stream.addOutputCallCount == 0)
    }

    @Test
    func testRetargetToSystemDefaultClearsTheDeviceIdentifier() async {
        let (session, _) = makeSession(micDeviceUID: "device-a")
        let stream = StubCaptureStream()
        session.attachStreamForTesting(stream)

        let didRetarget = await session.retargetMic(deviceUID: nil)

        #expect(didRetarget)
        #expect(stream.appliedMicDeviceUIDs == [nil])
        #expect(session.currentMicDeviceUID == nil)
    }

    @Test
    func testFailedRetargetKeepsPreviousDeviceAndReportsFailure() async {
        let (session, _) = makeSession(micDeviceUID: "device-a")
        let stream = StubCaptureStream()
        stream.updateError = StubUpdateError()
        session.attachStreamForTesting(stream)

        let didRetarget = await session.retargetMic(deviceUID: "device-b")

        #expect(!didRetarget)
        #expect(session.currentMicDeviceUID == "device-a")
        // Capture continues: the stream is neither stopped nor restarted on failure.
        #expect(stream.stopCallCount == 0)
        #expect(stream.startCallCount == 0)
    }

    @Test
    func testFailedRetargetRollsBackRetainedConfiguration() async {
        let (session, _) = makeSession(micDeviceUID: "device-a")
        let stream = StubCaptureStream()
        stream.updateError = StubUpdateError()
        session.attachStreamForTesting(stream)

        _ = await session.retargetMic(deviceUID: "device-b")
        stream.updateError = nil
        // A later successful retarget must not carry over the rejected value; the configuration
        // has to still describe what the stream actually has.
        let didRetarget = await session.retargetMic(deviceUID: "device-c")

        #expect(didRetarget)
        #expect(stream.appliedMicDeviceUIDs == ["device-b", "device-c"])
        #expect(session.currentMicDeviceUID == "device-c")
    }

    @Test
    func testRetargetWithoutRunningStreamFails() async {
        let (session, _) = makeSession(micDeviceUID: "device-a")

        let didRetarget = await session.retargetMic(deviceUID: "device-b")

        #expect(!didRetarget)
        #expect(session.currentMicDeviceUID == "device-a")
    }
}

struct CaptureStartRetryTests {
    private func makeSession(unified: Bool) -> (
        start: (RetryCaptureStream) async throws -> Void,
        stop: () async -> Void
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = UnifiedCaptureSession(
            micFileURL: root.appendingPathComponent("mic.wav"),
            appFileURL: unified ? root.appendingPathComponent("app.wav") : nil,
            processID: unified ? 1234 : nil, micDeviceUID: nil
        )
        return ({ try await session.start(stream: $0, retryDelay: .zero) }, { await session.stop() })
    }

    @Test(arguments: [false, true])
    func failedStartStopsBeforeRetryAndSuccessfulStreamIsRetained(unified: Bool) async throws {
        let session = makeSession(unified: unified)
        let stream = RetryCaptureStream(failures: 1)
        try await session.start(stream)
        #expect(stream.events == ["start", "failure", "stop", "start"])
        await session.stop()
        #expect(stream.events == ["start", "failure", "stop", "start", "stop"])
    }

    @Test(arguments: [false, true])
    func finalFailedAttemptIsAlsoStopped(unified: Bool) async {
        let session = makeSession(unified: unified)
        let stream = RetryCaptureStream(failures: 3)
        do {
            try await session.start(stream)
            Issue.record("Expected startup failure")
        } catch {
            #expect(error is RecordingError)
        }
        #expect(stream.events == ["start", "failure", "stop", "start", "failure", "stop", "start", "failure", "stop"])
        await session.stop()
        #expect(stream.events.count == 9)
    }

    @Test(arguments: [false, true])
    func cleanupFailurePreventsRetry(unified: Bool) async {
        let session = makeSession(unified: unified)
        let stream = RetryCaptureStream(failures: 1, stopFails: true)
        do {
            try await session.start(stream)
            Issue.record("Expected cleanup failure")
        } catch {
            #expect(error.localizedDescription.contains("Capture cleanup failed"))
        }
        #expect(stream.events == ["start", "failure", "stop"])
    }

    @Test(arguments: [false, true])
    func cancellationStopsTheAttemptWithoutRetry(unified: Bool) async {
        let session = makeSession(unified: unified)
        let stream = RetryCaptureStream(failures: 1, cancelled: true)
        do {
            try await session.start(stream)
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(stream.events == ["start", "failure", "stop"])
    }
}

private final class RetryCaptureStream: UnifiedCaptureStreaming, @unchecked Sendable {
    private var failures: Int
    private let stopFails: Bool
    private let cancelled: Bool
    private(set) var events: [String] = []

    init(failures: Int, stopFails: Bool = false, cancelled: Bool = false) {
        self.failures = failures
        self.stopFails = stopFails
        self.cancelled = cancelled
    }

    func startCapture() async throws {
        events.append("start")
        if failures > 0 {
            failures -= 1
            events.append("failure")
            if cancelled { throw CancellationError() }
            throw StubUpdateError()
        }
    }
    func stopCapture() async throws {
        events.append("stop")
        if stopFails { throw StubUpdateError() }
    }
    func addStreamOutput(_: SCStreamOutput, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue?) throws {}
    func updateConfiguration(_: SCStreamConfiguration) async throws {}
}

/// A gate that stays open after cleanup, including for late teardown calls.
final class BlockedCaptureStream: UnifiedCaptureStreaming, @unchecked Sendable {
    enum Call { case start, update, stop }
    let blocked: Call
    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "ScribermanTests.BlockedStream.\(UUID().uuidString)")
    private var open = false
    private let lock = NSLock()
    private var blockedCount = 0
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var stops = 0
    private var updates = 0
    var updateCount: Int { lock.withLock { updates } }
    init(_ blocked: Call) { self.blocked = blocked }
    var blockedCallCount: Int { lock.withLock { blockedCount } }
    var stopCount: Int { lock.withLock { stops } }
    func release() {
        condition.lock()
        open = true
        condition.broadcast()
        condition.unlock()
    }
    private func blockThread() {
        let waiters = lock.withLock {
            blockedCount += 1
            let waiters = blockedWaiters
            blockedWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
        condition.lock()
        while !open { condition.wait() }
        condition.unlock()
        lock.withLock { blockedCount -= 1 }
    }
    func waitUntilBlocked() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if blockedCount > 0 { continuation.resume() }
                else { blockedWaiters.append(continuation) }
            }
        }
    }
    private func wait() async {
        await withCheckedContinuation { continuation in
            queue.async { self.blockThread(); continuation.resume() }
        }
    }
    func startCapture() async throws { if blocked == .start { await wait() } }
    func updateConfiguration(_: SCStreamConfiguration) async throws {
        lock.withLock { updates += 1 }
        if blocked == .update { await wait() }
    }
    func stopCapture() async throws {
        if blocked == .stop { await wait() }
        lock.withLock { stops += 1 }
    }
    func addStreamOutput(_: SCStreamOutput, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue?) throws {}
}

final class CallCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var completed: Bool { lock.withLock { done } }
    func finish() { lock.withLock { done = true } }
}

struct BoundedCaptureCallTests {
    @Test(arguments: [false, true])
    func hungStartTimesOutAndLateStartIsStopped(unified: Bool) async throws {
        try await withBlockedStream(.start, unified: unified) { session, stream in
            let finished = CallCompletion()
            let task = Task {
                do {
                    try await session.start(stream: stream)
                    Issue.record("A timed out start succeeded")
                } catch {
                    #expect(error.localizedDescription == "Recording failed to start: no audio.")
                }
                finished.finish()
            }
            try await Task.sleep(for: .seconds(2))
            try await Task.sleep(for: .seconds(1))
            #expect(finished.completed)
            #expect(!session.isStreamLive)
            stream.release()
            await task.value
            await session.stop()
            #expect(await captureCallEventually { stream.stopCount > 0 })
            #expect(!session.isStreamLive)
        }
    }

    @Test(arguments: [false, true])
    func hungStopReturnsAndDropsLateBuffers(unified: Bool) async throws {
        try await withBlockedStream(.stop, unified: unified) { session, stream in
            session.attachStreamForTesting(stream)
            let finished = CallCompletion()
            let task = Task { await session.stop(); finished.finish() }
            try await Task.sleep(for: .seconds(2))
            #expect(finished.completed)
            #expect(!session.isStreamLive)
            stream.release()
            await task.value
        }
    }

    @Test
    func hungMicSwitchKeepsStreamAndIgnoresLateSuccess() async throws {
        try await withBlockedStream(.update, unified: false) { session, stream in
            session.attachStreamForTesting(stream)
            let finished = CallCompletion()
            let update = Task {
                let result = await session.retargetMic(deviceUID: "device-b")
                finished.finish()
                return result
            }
            try await Task.sleep(for: .seconds(2))
            #expect(finished.completed)
            #expect(session.isStreamLive)
            #expect(stream.stopCount == 0)
            #expect(session.currentMicDeviceUID == "device-a")
            #expect(session.configuration.microphoneCaptureDeviceID == "device-a")
            stream.release()
            #expect(await update.value == false)
            #expect(await captureCallEventually { stream.blockedCallCount == 0 })
            #expect(session.currentMicDeviceUID == "device-a")
            #expect(session.configuration.microphoneCaptureDeviceID == "device-a")
            #expect(stream.stopCount == 0)
            #expect(await session.retargetMic(deviceUID: "device-c") == false)
            #expect(stream.updateCount == 1)
        }
    }

    @Test
    func stopDuringUpdateDoesNotPublishItsLateDevice() async throws {
        try await withBlockedStream(.update, unified: false) { session, stream in
            session.attachStreamForTesting(stream)
            let update = Task { await session.retargetMic(deviceUID: "device-b") }
            try await Task.sleep(for: .seconds(1))
            await session.stop()
            stream.release()
            #expect(await update.value == false)
            #expect(session.currentMicDeviceUID == "device-a")
        }
    }

    @Test(arguments: [false, true])
    func discoveryAndStartShareOneDeadlineAndLateDiscoveryNeverStarts(unified: Bool) async throws {
        try await withBlockedStream(.start, unified: unified) { session, stream in
            let finished = CallCompletion()
            let task = Task {
                do {
                    try await session.start(discoverStream: {
                        try await stream.startCapture() // Blocks the content provider, not session start.
                        return CaptureStreamReference(stream: stream)
                    })
                    Issue.record("Late content started a stream")
                } catch {
                    #expect(error.localizedDescription == "Recording failed to start: no audio.")
                }
                finished.finish()
            }
            try await Task.sleep(for: .seconds(2))
            try await Task.sleep(for: .seconds(1))
            #expect(finished.completed)
            stream.release()
            await task.value
            #expect(await captureCallEventually { stream.stopCount > 0 })
            #expect(!session.isStreamLive)
        }
    }

    @Test(arguments: [false, true])
    func retiredHandlersCannotReopenFilesOrWriteToAdoptedWriters(unified: Bool) async throws {
        try await withBlockedStream(.stop, unified: unified) { session, stream in
            let sample = try CaptureAudioGateTests.makeSampleBuffer(
                Array(repeating: CaptureAudioGateTests.before, count: 960), sampleRate: 48_000,
                hostTime: HostNanoseconds(nanoseconds: 1_000_000_000))
            session.micHandler.processSampleBufferForTesting(sample)
            if unified { session.appHandler.processSampleBufferForTesting(sample) }
            session.attachStreamForTesting(stream)
            await session.stopStreamPreservingOutput()
            let micBefore = session.micFramesWritten
            let appBefore = session.appFramesWritten
            session.micHandler.processSampleBufferForTesting(sample)
            session.appHandler.processSampleBufferForTesting(sample)
            session.streamers.mic.close()
            session.streamers.app.close()
            #expect(session.micFramesWritten == micBefore)
            #expect(session.appFramesWritten == appBefore)
            #expect(session.micWriteFailureCount == 0)
            #expect(session.appWriteFailureCount == 0)
        }
    }

    @Test(arguments: [false, true])
    func partialTimedOutStartKeepsWrittenAudioAndRejectsLateBuffers(unified: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await withBlockedStream(.start, unified: unified, root: root) { session, stream in
            let sample = try CaptureAudioGateTests.makeSampleBuffer(
                Array(repeating: CaptureAudioGateTests.before, count: 960), sampleRate: 48_000,
                hostTime: HostNanoseconds(nanoseconds: 1_000_000_000))
            session.micHandler.processSampleBufferForTesting(sample)
            if unified { session.appHandler.processSampleBufferForTesting(sample) }
            do { try await session.start(stream: stream); Issue.record("Expected timeout") } catch { }
            await session.stop()
            let micURL = root.appendingPathComponent("mic.wav")
            let frames = try AVAudioFile(forReading: micURL).length
            #expect(frames > 0)
            #expect(AudioFileStreamer.loadTimingSidecar(for: micURL)?.totalFrames == Int(frames))
            session.micHandler.processSampleBufferForTesting(sample)
            session.appHandler.processSampleBufferForTesting(sample)
            stream.release()
            #expect(await captureCallEventually { stream.stopCount > 0 })
            #expect(try AVAudioFile(forReading: micURL).length == frames)
            #expect(session.micWriteFailureCount == 0)
            if unified {
                let appURL = root.appendingPathComponent("app.wav")
                let appFrames = try AVAudioFile(forReading: appURL).length
                #expect(appFrames > 0)
                #expect(AudioFileStreamer.loadTimingSidecar(for: appURL)?.totalFrames == Int(appFrames))
                #expect(session.appWriteFailureCount == 0)
            }
        }
    }

    private func withBlockedStream(
        _ call: BlockedCaptureStream.Call, unified: Bool,
        root: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        _ body: (UnifiedCaptureSession, BlockedCaptureStream) async throws -> Void
    ) async throws {
        let session = UnifiedCaptureSession(
            micFileURL: root.appendingPathComponent("mic.wav"),
            appFileURL: unified ? root.appendingPathComponent("app.wav") : nil,
            processID: unified ? 1234 : nil, micDeviceUID: "device-a"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stream = BlockedCaptureStream(call)
        var failure: (any Error)?
        do { try await body(session, stream) } catch { failure = error }
        stream.release()
        await session.stop()
        #expect(await captureCallEventually { stream.blockedCallCount == 0 })
        try? FileManager.default.removeItem(at: root)
        if let failure { throw failure }
    }
}

func captureCallEventually(_ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    return condition()
}
