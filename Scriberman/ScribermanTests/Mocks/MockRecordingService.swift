import CoreAudio
import CoreGraphics
import Foundation
@testable import Scriberman

final class MockRecordingService: RecordingServiceProtocol, @unchecked Sendable {
    var isRecordingOverride = false
    var audioLevelOverride: Float = 0
    var startShouldThrow: RecordingError?
    var startThrowSequence: [RecordingError] = []
    var startReturns: UUID = UUID()
    var stopReturns: UUID?
    var startCalls: [(workspace: Workspace, micDeviceID: AudioDeviceID?, captureDisplayID: CGDirectDisplayID?, capturedAppName: String?, appProcessID: pid_t?, title: String?)] = []
    var retargetMicCalls: [String?] = []
    var pendingError: RecordingError?

    func liveAudioStream() async -> AsyncStream<([Float], AudioSource, Double)> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

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

    func captureHealthSnapshot() async -> CaptureHealthMonitor.Snapshot {
        captureHealthSnapshotCallCount += 1
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

    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        captureDisplayID: CGDirectDisplayID?,
        capturedAppName: String?,
        appProcessID: pid_t?,
        title: String?
    ) async throws(RecordingError) -> UUID {
        startCalls.append((
            workspace: workspace,
            micDeviceID: micDeviceID,
            captureDisplayID: captureDisplayID,
            capturedAppName: capturedAppName,
            appProcessID: appProcessID,
            title: title
        ))
        if !startThrowSequence.isEmpty {
            throw startThrowSequence.removeFirst()
        }
        if let startShouldThrow {
            throw startShouldThrow
        }
        return startReturns
    }

    func stopRecording() async -> UUID? {
        stopReturns
    }

    func consumePendingError() async -> RecordingError? {
        defer { pendingError = nil }
        return pendingError
    }

    func retargetMic(desiredDeviceUID: String?) async {
        retargetMicCalls.append(desiredDeviceUID)
    }
}
