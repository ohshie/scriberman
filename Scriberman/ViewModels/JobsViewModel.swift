import Foundation
import SwiftData

@MainActor
final class JobsViewModel: ObservableObject {
    private let workspaceService: WorkspaceService
    private let transcriptionService: TranscriptionService

    init(workspaceService: WorkspaceService, transcriptionService: TranscriptionService) {
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
                await transcriptionService.transcribe(session: session, workspace: workspace, context: context)
            } catch {
                await MainActor.run {
                    session.status = .error(error.localizedDescription)
                    session.errorMessage = error.localizedDescription
                    try? context.save()
                }
            }
        }
    }

    func retry(session: RecordingSession, context: ModelContext) {
        session.status = .recorded
        session.errorMessage = nil
        try? context.save()
    }

    func delete(session: RecordingSession, context: ModelContext) {
        let audioURL = URL(fileURLWithPath: session.audioURL)
        if FileManager.default.fileExists(atPath: audioURL.path) {
            try? FileManager.default.removeItem(at: audioURL)
        }
        context.delete(session)
        try? context.save()
    }
}
