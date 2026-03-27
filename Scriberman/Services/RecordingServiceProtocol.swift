import Foundation

protocol RecordingServiceProtocol {
    func isRecording() async -> Bool
    func audioLevel() async -> Float
    func startRecording(in workspace: Workspace) async throws
    func stopRecording() async -> RecordingSession?
}
