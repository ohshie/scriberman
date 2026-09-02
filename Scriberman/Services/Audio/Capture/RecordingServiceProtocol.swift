import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
import SwiftData

protocol RecordingServiceProtocol: Sendable {
    func liveAudioStream() async -> AsyncStream<([Float], AudioSource, Double)>
    func isRecording() async -> Bool
    func audioLevel() async -> Float
    func audioLevels() async -> (mic: Float, app: Float)
    /// When each source last produced sustained audio activity. Unlike `audioLevels()`,
    /// these stop advancing when a source stops delivering buffers, so they can be used to
    /// measure idleness. `nil` means the source has never been active (or is not tracked).
    func activityTimestamps() async -> (mic: Date?, app: Date?)
    /// Frames written per source since capture started. Unlike `audioLevels()` and
    /// `activityTimestamps()`, this counts buffers landed rather than sound detected, so a silent
    /// room still reports a healthy capture. `mic` is `nil` under the recorder fallback, which does
    /// not write through the shared file streamer; `app` is `nil` when app audio is not captured.
    func captureFrameCounts() async -> (mic: Int64?, app: Int64?, micWriteFailures: Int, appWriteFailures: Int)

    /// Everything the capture-health monitor needs in one call: the frame counts above plus a
    /// monotonic count of capture streams that stopped on their own during this recording.
    ///
    /// Unlike `consumePendingError()`, reading this does not spend anything — the monitor samples
    /// it every evaluation, while the pending error is consumed once when a failure is reported.
    func captureHealthSnapshot() async -> CaptureHealthMonitor.Snapshot
    /// Restarts audio capture with the same configuration and files, keeping the session. Returns
    /// whether capture started again.
    func restartAudioCapture() async -> Bool
    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        captureDisplayID: CGDirectDisplayID?,
        capturedAppName: String?,
        appProcessID: pid_t?,
        title: String?
    ) async throws(RecordingError) -> UUID
    func stopRecording() async -> UUID?
    func consumePendingError() async -> RecordingError?
    func retargetMic(desiredDeviceUID: String?) async
}
