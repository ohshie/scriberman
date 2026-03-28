import Foundation
import OSLog
import SwiftData

@MainActor
final class JobsViewModel: ObservableObject {
    private let workspaceService: WorkspaceServiceProtocol
    private let transcriptionService: TranscriptionServiceProtocol
    private let logger = Logger(subsystem: "Scriberman", category: "JobsViewModel")

    init(workspaceService: WorkspaceServiceProtocol, transcriptionService: TranscriptionServiceProtocol) {
        self.workspaceService = workspaceService
        self.transcriptionService = transcriptionService
    }

    func refresh() async {
        _ = await workspaceService.currentWorkspace()
    }

    func transcribe(session: RecordingSession, context: ModelContext) {
        guard case .recorded = session.status else {
            return
        }

        session.status = .transcribing
        session.errorMessage = nil
        try? context.save()

        Task {
            do {
                let workspace = try await workspaceService.requireWritableWorkspace()
                let transcript = try await transcriptionService.transcribe(session: session, workspace: workspace)
                session.transcript = transcript
                session.status = .done
                session.errorMessage = nil
                try? context.save()
            } catch {
                logger.error("Transcription failed for session \(session.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                session.status = .error(error.localizedDescription)
                session.errorMessage = error.localizedDescription
                try? context.save()
            }
        }
    }

    func retry(session: RecordingSession, context: ModelContext) {
        session.status = .recorded
        session.errorMessage = nil
        try? context.save()
    }

    func delete(session: RecordingSession, context: ModelContext) {
        let micAudioURL = URL(fileURLWithPath: session.micAudioURL)
        if FileManager.default.fileExists(atPath: micAudioURL.path) {
            try? FileManager.default.removeItem(at: micAudioURL)
        }
        context.delete(session)
        try? context.save()
    }
}
