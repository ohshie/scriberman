import Foundation
import SwiftData

protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(
        sessionID: UUID,
        modelContainer: ModelContainer,
        workspace: Workspace,
        pipelineSettings: LiveTranscriptionPipelineSettings
    ) async throws -> Transcript
}

extension TranscriptionServiceProtocol {
    /// Convenience for existential callers (default arguments don't apply
    /// through a protocol type): transcribe with default pipeline settings.
    func transcribe(sessionID: UUID, modelContainer: ModelContainer, workspace: Workspace) async throws -> Transcript {
        try await transcribe(
            sessionID: sessionID,
            modelContainer: modelContainer,
            workspace: workspace,
            pipelineSettings: .defaults
        )
    }
}
