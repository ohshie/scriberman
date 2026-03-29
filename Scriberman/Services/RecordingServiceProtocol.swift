import CoreAudio
import Foundation

@preconcurrency
protocol RecordingServiceProtocol {
    func isRecording() async -> Bool
    func audioLevel() async -> Float
    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        capturedAppName: String?,
        appProcessID: pid_t?,
        title: String?
    ) async throws
    func stopRecording() async -> RecordingSession?
    func consumePendingError() async -> RecordingError?
}
