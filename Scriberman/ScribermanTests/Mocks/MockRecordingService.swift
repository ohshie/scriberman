import CoreAudio
import CoreGraphics
import Foundation
import SwiftData
@testable import Scriberman

final class MockRecordingService: RecordingServiceProtocol, @unchecked Sendable {
    var isRecordingOverride = false
    var audioLevelOverride: Float = 0
    var startShouldThrow: RecordingError?
    var startThrowSequence: [RecordingError] = []
    var startReturns: UUID = UUID()
    var stopReturns: UUID?
    var startCalls: [(workspace: Workspace, micDeviceID: AudioDeviceID?, preferredMicDeviceUID: String?, captureDisplayID: CGDirectDisplayID?, capturedAppName: String?, appProcessID: pid_t?, title: String?, audioSyncFlags: AudioSyncFlags)] = []
    var retargetMicCalls: [String?] = []
    var pendingError: RecordingError?

    var liveAudioContinuation: AsyncStream<LiveAudioChunk>.Continuation?

    /// When set, a successful start saves a recording session to this container, as the real
    /// service does, and returns its id instead of `startReturns`. Stop then returns that id
    /// unless `stopReturns` is set.
    var persistsSessionsIn: ModelContainer?
    private var persistedSessionID: UUID?
    /// When set, what `isScreenCaptureActive()` answers. Otherwise it answers whether the last
    /// successful start asked for a display.
    var screenCaptureActiveOverride: Bool?
    private var lastStartCapturedDisplay = false

    func isRecording() async -> Bool {
        isRecordingOverride
    }

    func audioLevel() async -> Float {
        max(audioLevelsOverride.mic, max(audioLevelsOverride.app, audioLevelOverride))
    }

    var audioLevelsOverride: (mic: Float, app: Float) = (0, 0)

    func audioLevels() async -> (mic: Float, app: Float) {
        (max(audioLevelsOverride.mic, audioLevelOverride), audioLevelsOverride.app)
    }

    var activityTimestampsOverride: (mic: Date?, app: Date?) = (nil, nil)

    func activityTimestamps() async -> (mic: Date?, app: Date?) {
        activityTimestampsOverride
    }

    /// Frame counts returned by `captureFrameCounts()`. Successive verification passes pop from
    /// the front when more than one is queued, so a test can model "dead, then healthy after the
    /// restart" without timing games.
    var frameCountQueue: [(mic: Int64?, app: Int64?)] = [(mic: 512, app: nil)]
    private(set) var frameCountCallCount = 0

    func captureFrameCounts() async -> (mic: Int64?, app: Int64?, micWriteFailures: Int, appWriteFailures: Int) {
        frameCountCallCount += 1
        let counts = frameCountQueue.count > 1 ? frameCountQueue.removeFirst() : (frameCountQueue.first ?? (mic: 512, app: nil))
        return (counts.mic, counts.app, 0, 0)
    }

    /// Snapshots returned by `captureHealthSnapshot()`. Deliberately separate state from
    /// `frameCountQueue`: capture-health evaluation and start verification run concurrently on the
    /// same recording, and sharing a pop-once queue would make each one consume the other's
    /// fixtures.
    var captureHealthSnapshotQueue: [CaptureHealthMonitor.Snapshot] = [
        CaptureHealthMonitor.Snapshot(micFrames: 512, appFrames: nil)
    ]
    private(set) var captureHealthSnapshotCallCount = 0

    /// When set, answers `captureHealthSnapshot()` in place of the queue.
    var captureHealthSnapshotProvider: (() -> CaptureHealthMonitor.Snapshot)?

    func captureHealthSnapshot() async -> CaptureHealthMonitor.Snapshot {
        captureHealthSnapshotCallCount += 1
        if let captureHealthSnapshotProvider {
            return captureHealthSnapshotProvider()
        }
        let fallback = CaptureHealthMonitor.Snapshot(micFrames: 512, appFrames: nil)
        guard captureHealthSnapshotQueue.count > 1 else {
            return captureHealthSnapshotQueue.first ?? fallback
        }
        return captureHealthSnapshotQueue.removeFirst()
    }

    var restartAudioCaptureResult = true
    private(set) var restartAudioCaptureCallCount = 0

    func restartAudioCapture() async -> Bool {
        restartAudioCaptureCallCount += 1
        return restartAudioCaptureResult
    }

    var restartAudioCaptureInPlaceResult = true
    private(set) var restartAudioCaptureInPlaceCallCount = 0

    func restartAudioCaptureInPlace() async -> Bool {
        restartAudioCaptureInPlaceCallCount += 1
        return restartAudioCaptureInPlaceResult
    }

    /// When set, a start waits at this gate before it records the call.
    var startGate: AsyncGate?

    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        preferredMicDeviceUID: String?,
        captureDisplayID: CGDirectDisplayID?,
        capturedAppName: String?,
        appProcessID: pid_t?,
        title: String?,
        liveAudioContinuation: AsyncStream<LiveAudioChunk>.Continuation?,
        liveAudioClock: LiveCaptureClock?,
        audioSyncFlags: AudioSyncFlags
    ) async throws(RecordingError) -> UUID {
        if let startGate {
            await startGate.pass()
        }
        startCalls.append((
            workspace: workspace,
            micDeviceID: micDeviceID,
            preferredMicDeviceUID: preferredMicDeviceUID,
            captureDisplayID: captureDisplayID,
            capturedAppName: capturedAppName,
            appProcessID: appProcessID,
            title: title,
            audioSyncFlags: audioSyncFlags
        ))
        if !startThrowSequence.isEmpty {
            throw startThrowSequence.removeFirst()
        }
        if let startShouldThrow {
            throw startShouldThrow
        }
        self.liveAudioContinuation = liveAudioContinuation
        lastStartCapturedDisplay = captureDisplayID != nil
        guard let persistsSessionsIn else {
            return startReturns
        }
        let context = ModelContext(persistsSessionsIn)
        let session = RecordingSession(
            duration: 0,
            micAudioURL: "/tmp/mock-mic.wav",
            appAudioURL: appProcessID != nil ? "/tmp/mock-app.wav" : nil,
            title: title ?? "",
            capturedAppName: capturedAppName,
            status: .recording
        )
        context.insert(session)
        try? context.save()
        persistedSessionID = session.id
        return session.id
    }

    func stopRecording() async -> UUID? {
        calls.append("stop")
        isPausedValue = false
        liveAudioContinuation?.finish()
        liveAudioContinuation = nil
        defer { persistedSessionID = nil }
        return stopReturns ?? persistedSessionID
    }

    func isScreenCaptureActive() async -> Bool {
        screenCaptureActiveOverride ?? lastStartCapturedDisplay
    }

    func consumePendingError() async -> RecordingError? {
        defer { pendingError = nil }
        return pendingError
    }

    func retargetMic(desiredDeviceUID: String?) async {
        retargetMicCalls.append(desiredDeviceUID)
    }

    // MARK: - Pause and resume

    /// The order of pause, resume and stop calls, each recorded when the call begins.
    private(set) var calls: [String] = []
    var pauseCallCount: Int { calls.filter { $0 == "pause" }.count }
    var resumeCallCount: Int { calls.filter { $0 == "resume" }.count }
    var pauseResult = true
    var resumeResult = true
    /// When set, a resume waits at this gate before it answers.
    var resumeGate: AsyncGate?
    private(set) var isPausedValue = false

    func pauseRecording() async -> Bool {
        calls.append("pause")
        if pauseResult {
            isPausedValue = true
        }
        return pauseResult
    }

    func resumeRecording() async -> Bool {
        calls.append("resume")
        if let resumeGate {
            await resumeGate.pass()
        }
        calls.append("resumed")
        if resumeResult {
            isPausedValue = false
        }
        return resumeResult
    }

    func isPaused() async -> Bool {
        isPausedValue
    }

    var capturedMicrophoneOverride: CapturedMicrophone?

    func capturedMicrophone() async -> CapturedMicrophone? {
        capturedMicrophoneOverride
    }
}

/// Holds whoever calls `pass()` until `open()`. `waitUntilHolding()` returns once someone waits.
actor AsyncGate {
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            held.append(continuation)
            watchers.forEach { $0.resume() }
            watchers = []
        }
    }

    func waitUntilHolding() async {
        guard held.isEmpty, !isOpen else { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func open() {
        isOpen = true
        held.forEach { $0.resume() }
        held = []
    }
}
