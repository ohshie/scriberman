import Foundation
@testable import Scriberman

final class MockTranscriptionService: TranscriptionServiceProtocol {
    var transcribeResult: Result<Transcript, Error> = .failure(MockTranscriptionServiceError.notConfigured)

    func transcribe(audioURL: URL, workspace: Workspace) async throws -> Transcript {
        try transcribeResult.get()
    }
}

enum MockTranscriptionServiceError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No transcription result configured"
        }
    }
}
