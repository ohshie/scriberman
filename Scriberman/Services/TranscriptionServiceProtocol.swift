import Foundation

protocol TranscriptionServiceProtocol {
    func transcribe(session: RecordingSession, workspace: Workspace) async throws -> Transcript
}
