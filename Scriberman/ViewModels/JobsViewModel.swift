import Foundation
import OSLog
import SwiftData
import UniformTypeIdentifiers

@MainActor
final class JobsViewModel: ObservableObject {
    enum SessionListItem: Identifiable {
        case recording(RecordingSession)
        case imported(ImportedSession)

        var id: String {
            switch self {
            case .recording(let session):
                return "recording:\(session.id.uuidString)"
            case .imported(let session):
                return "imported:\(session.id.uuidString)"
            }
        }

        var createdAt: Date {
            switch self {
            case .recording(let session):
                return session.createdAt
            case .imported(let session):
                return session.createdAt
            }
        }
    }

    private let workspaceService: WorkspaceServiceProtocol
    private let transcriptionService: TranscriptionServiceProtocol
    private let retranscriptionService: RetranscriptionService
    private let audioImportService: AudioImportService
    private let logger = Logger(subsystem: "Scriberman", category: "JobsViewModel")

    init(
        workspaceService: WorkspaceServiceProtocol,
        transcriptionService: TranscriptionServiceProtocol,
        retranscriptionService: RetranscriptionService,
        audioImportService: AudioImportService
    ) {
        self.workspaceService = workspaceService
        self.transcriptionService = transcriptionService
        self.retranscriptionService = retranscriptionService
        self.audioImportService = audioImportService
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

    func importAudio(urls: [URL], context: ModelContext) async {
        let audioURLs = urls.filter { Self.isAudioURL($0) }
        guard !audioURLs.isEmpty else {
            return
        }

        do {
            let workspace = try await workspaceService.requireWritableWorkspace()
            for audioURL in audioURLs {
                await audioImportService.importAudio(from: audioURL, workspace: workspace, context: context)
            }
        } catch {
            logger.error("Import skipped because workspace is unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func retryImported(session: ImportedSession, context: ModelContext) {
        guard session.mixdownURL != nil else {
            return
        }
        session.status = .transcribing
        session.errorMessage = nil
        try? context.save()

        Task {
            do {
                let workspace = try await workspaceService.requireWritableWorkspace()
                await retranscriptionService.retranscribe(session: session, workspace: workspace, context: context)
            } catch {
                session.status = .error(error.localizedDescription)
                session.errorMessage = error.localizedDescription
                try? context.save()
            }
        }
    }

    func deleteImported(session: ImportedSession, context: ModelContext) {
        if let mixdownPath = session.mixdownURL {
            let mixdownURL = URL(fileURLWithPath: mixdownPath)
            if FileManager.default.fileExists(atPath: mixdownURL.path) {
                try? FileManager.default.removeItem(at: mixdownURL)
            }
            let folderURL = mixdownURL.deletingLastPathComponent()
            if let remaining = try? FileManager.default.contentsOfDirectory(atPath: folderURL.path), remaining.isEmpty {
                try? FileManager.default.removeItem(at: folderURL)
            }
        }
        context.delete(session)
        try? context.save()
    }

    private static func isAudioURL(_ url: URL) -> Bool {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           contentType.conforms(to: .audio) {
            return true
        }

        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return false
        }
        return type.conforms(to: .audio)
    }
}
