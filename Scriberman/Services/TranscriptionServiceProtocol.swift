import Foundation

protocol TranscriptionServiceProtocol {
    func transcribe(audioURL: URL, workspace: Workspace) async throws -> Transcript
}
