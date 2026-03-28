import Foundation
import SwiftData

@MainActor
final class JobsViewModel: ObservableObject {
    private let workspaceService: WorkspaceServiceProtocol
    private let transcriptionService: TranscriptionServiceProtocol

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

        let micAudioURL = URL(fileURLWithPath: session.micAudioURL)
        session.status = .transcribing
        session.errorMessage = nil
        try? context.save()

        Task {
            do {
                let workspace = try await workspaceService.requireWritableWorkspace()
                let transcript = try await transcriptionService.transcribe(audioURL: micAudioURL, workspace: workspace)
                session.transcript = transcript
                session.status = .done
                session.errorMessage = nil
                try? context.save()
            } catch {
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
