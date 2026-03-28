import Foundation
import OSLog
import SwiftData
import UniformTypeIdentifiers

@MainActor
final class JobsViewModel: ObservableObject {
    enum SessionListItem: Identifiable, Hashable {
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

        static func == (lhs: SessionListItem, rhs: SessionListItem) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    enum SessionDateGroup: CaseIterable, Identifiable, Hashable {
        case today
        case yesterday
        case thisWeek
        case earlier

        var id: String {
            title
        }

        var title: String {
            switch self {
            case .today:
                return "Today"
            case .yesterday:
                return "Yesterday"
            case .thisWeek:
                return "This Week"
            case .earlier:
                return "Earlier"
            }
        }
    }

    struct SessionDateSection: Identifiable, Hashable {
        let group: SessionDateGroup
        let items: [SessionListItem]

        var id: SessionDateGroup { group }
        var title: String { group.title }
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

    func groupedSections(
        for items: [SessionListItem],
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> [SessionDateSection] {
        SessionDateGroup.allCases.compactMap { group in
            let sectionItems = items.filter {
                sessionDateGroup(for: $0.createdAt, referenceDate: referenceDate, calendar: calendar) == group
            }

            guard !sectionItems.isEmpty else {
                return nil
            }

            return SessionDateSection(group: group, items: sectionItems.sorted { $0.createdAt > $1.createdAt })
        }
    }

    func sessionDateGroup(
        for date: Date,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> SessionDateGroup {
        if calendar.isDate(date, inSameDayAs: referenceDate) {
            return .today
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceDate),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }

        if calendar.isDate(date, equalTo: referenceDate, toGranularity: .weekOfYear) {
            return .thisWeek
        }

        return .earlier
    }

    func relativeTimestampText(
        for date: Date,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        Self.relativeTimestampText(for: date, referenceDate: referenceDate, calendar: calendar)
    }

    static func relativeTimestampText(
        for date: Date,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: referenceDate) {
            let interval = max(0, Int(referenceDate.timeIntervalSince(date).rounded(.down)))

            if interval < 60 {
                return "Now"
            }

            if interval < 3_600 {
                return "\(max(1, interval / 60))m ago"
            }

            return "\(max(1, interval / 3_600))h ago"
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
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

    func reprocess(session: any TranscribableSession, context: ModelContext) {
        guard session.mixdownURL != nil else {
            session.status = .error("No mixdown available for reprocessing")
            session.errorMessage = "No mixdown available for reprocessing"
            try? context.save()
            return
        }

        session.status = .retranscribing
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
