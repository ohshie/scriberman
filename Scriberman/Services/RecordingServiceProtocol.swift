import CoreAudio
import Foundation

protocol RecordingServiceProtocol {
    func isRecording() async -> Bool
    func audioLevel() async -> Float
    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        tapID: AudioObjectID?,
        aggregateDeviceID: AudioDeviceID?,
        capturedAppName: String?,
        appProcessID: pid_t?
    ) async throws
    func stopRecording() async -> RecordingSession?
    func consumePendingError() async -> RecordingError?
}
