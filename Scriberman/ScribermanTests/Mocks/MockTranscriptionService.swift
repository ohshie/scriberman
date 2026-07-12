import Foundation
import SwiftData
@testable import Scriberman

final class MockTranscriptionService: TranscriptionServiceProtocol, @unchecked Sendable {
    var transcribeResult: Result<Transcript, Error> = .failure(MockTranscriptionServiceError.notConfigured)
    var lastPipelineSettings: LiveTranscriptionPipelineSettings?

    func transcribe(
        sessionID: UUID,
        modelContainer: ModelContainer,
        workspace: Workspace,
        pipelineSettings: LiveTranscriptionPipelineSettings
    ) async throws -> Transcript {
        lastPipelineSettings = pipelineSettings
        return try transcribeResult.get()
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
