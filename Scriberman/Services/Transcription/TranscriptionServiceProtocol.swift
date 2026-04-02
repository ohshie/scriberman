import Foundation
import SwiftData

protocol TranscriptionServiceProtocol: Sendable {
    func transcribe(sessionID: UUID, modelContainer: ModelContainer, workspace: Workspace) async throws -> Transcript
}
