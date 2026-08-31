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
