import Foundation
import SwiftData

protocol TranscriptionServiceProtocol {
    func transcribe(sessionID: UUID, modelContainer: ModelContainer, workspace: Workspace) async throws -> Transcript
}
