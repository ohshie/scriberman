import CoreAudio
import Foundation

protocol RecordingServiceProtocol {
    func isRecording() async -> Bool
    func audioLevel() async -> Float
    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        tapID: AudioObjectID?,
        aggregateDeviceID: AudioDeviceID?
    ) async throws
    func stopRecording() async -> RecordingSession?
    func consumePendingError() async -> RecordingError?
}
