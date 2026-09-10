import AppKit
import Foundation
import Observation
import OSLog
import SwiftData
import UniformTypeIdentifiers

@MainActor
@Observable
final class JobsViewModel {
    enum SessionListItem: Identifiable, Hashable {
        case pending(PendingSession)
        case recording(RecordingSession)
        case imported(ImportedSession)

        var id: String {
            switch self {
            case .pending(let session):
                return "pending:\(session.id.uuidString)"
            case .recording(let session):
                return "recording:\(session.id.uuidString)"
            case .imported(let session):
                return "imported:\(session.id.uuidString)"
            }
        }

        var createdAt: Date {
            switch self {
            case .pending(let session):
                return session.createdAt
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

    /// What a search query matched a session on.
    ///
    /// A distinction the results have to keep: only a transcript match has a line to quote, so only
    /// a transcript match carries a snippet.
    enum SessionSearchMatchKind: Hashable {
        case title
        case transcript
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
    private let transcriptExportService: TranscriptExportService
    private let markdownRenderer: MarkdownRenderer
    private let savePanelPresenter: @MainActor (_ suggestedName: String) -> URL?
    private let logger = Logger(subsystem: "Scriberman", category: "JobsViewModel")

    // Injected post-init by AppState (same pattern as NewSessionViewModel);
    // offline passes fall back to defaults when unset.
    var settingsViewModel: SettingsViewModel?

    private var currentPipelineSettings: LiveTranscriptionPipelineSettings {
        settingsViewModel?.pipelineSettings ?? .defaults
    }

    init(
        workspaceService: WorkspaceServiceProtocol,
        transcriptionService: TranscriptionServiceProtocol,
        retranscriptionService: RetranscriptionService,
        audioImportService: AudioImportService,
        transcriptExportService: TranscriptExportService = TranscriptExportService(),
        markdownRenderer: MarkdownRenderer = MarkdownRenderer(),
        savePanelPresenter: @escaping @MainActor (_ suggestedName: String) -> URL? = JobsViewModel.defaultSavePanelPresenter(suggestedName:)
    ) {
        self.workspaceService = workspaceService
        self.transcriptionService = transcriptionService
        self.retranscriptionService = retranscriptionService
        self.audioImportService = audioImportService
        self.transcriptExportService = transcriptExportService
        self.markdownRenderer = markdownRenderer
        self.savePanelPresenter = savePanelPresenter
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
                if case .pending = $0 {
                    return false
                }
                return sessionDateGroup(for: $0.createdAt, referenceDate: referenceDate, calendar: calendar) == group
            }

            guard !sectionItems.isEmpty else {
                return nil
            }

            return SessionDateSection(group: group, items: sectionItems.sorted { $0.createdAt > $1.createdAt })
        }
    }

    func shouldDiscardPendingSessionOnSelectionChange(
        pendingSession: PendingSession?,
        newSelection: SessionListItem?,
        isNewSessionIdle: Bool
    ) -> Bool {
        guard pendingSession != nil, let newSelection else {
            return false
        }

        if case .pending = newSelection {
            return false
        }

        return isNewSessionIdle
    }

    func sessionItems(
        recordingSessions: [RecordingSession],
        importedSessions: [ImportedSession],
        preserving selectedItem: SessionListItem?
    ) -> [SessionListItem] {
        var recordingItems = recordingSessions.map(SessionListItem.recording)
        let importedItems = importedSessions.map(SessionListItem.imported)

        // Keep selected recordings visible until SwiftData query refresh catches up.
        if let selectedItem,
           case .recording = selectedItem,
           !recordingItems.contains(where: { $0.id == selectedItem.id }) {
            recordingItems.append(selectedItem)
        }

        let combined = (recordingItems + importedItems).sorted { $0.createdAt > $1.createdAt }
        return applyingSearchQuery(to: applyingTagFilter(to: combined))
    }

    /// Narrows the list to recordings carrying any of the selected tags.
    ///
    /// Union rather than intersection: intersecting two tags over a personal archive returns almost
    /// nothing, which would make multi-selection useless.
    ///
    /// While a filter is active, imported and pending sessions drop out. They carry no tags, so
    /// they cannot match — and showing them anyway would mean a filtered list still contains rows
    /// the filter says nothing about.
    ///
    /// Applied here, after the selection-preserving branch above, so filtering the selected item
    /// out wins over keeping it visible.
    private func applyingTagFilter(to items: [SessionListItem]) -> [SessionListItem] {
        guard !selectedTagIDs.isEmpty else { return items }

        // Only tags some recording actually carries can filter. A tag that lost its last recording
        // has no chip any more, so leaving it in the selection would filter the list to nothing
        // with no visible way to undo it. Ignoring it instead makes the selection self-healing.
        var present: Set<UUID> = []
        for item in items {
            if case .recording(let session) = item {
                for tag in session.tags { present.insert(tag.id) }
            }
        }
        let effective = selectedTagIDs.intersection(present)
        guard !effective.isEmpty else { return items }

        return items.filter { item in
            guard case .recording(let session) = item else { return false }
            return session.tags.contains { effective.contains($0.id) }
        }
    }

    /// What the search field holds. Empty, or nothing but whitespace, means no search.
    ///
    /// Beside `selectedTagIDs` rather than in a layer of its own: the two narrow the same list and
    /// combine with AND, and keeping them together is what makes that composition visible.
    var searchQuery: String = ""

    /// The query with its surrounding whitespace removed, or `nil` when there is nothing to search
    /// for. Every search path goes through this, so "    " and "" behave identically.
    var activeSearchQuery: String? {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Narrows the list to sessions whose title or transcript contains the query.
    ///
    /// Applied after the tag filter, which is what makes the two AND: tags narrow the set, the
    /// query searches within it.
    ///
    /// A query that matches nothing yields an empty list. It deliberately does not fall back to
    /// showing everything — a list that ignores the query looks like a search that found the whole
    /// library.
    ///
    /// Matching is `localizedStandardContains`, which is case- and diacritic-insensitive, the same
    /// comparison the in-transcript find bar uses. A pending session drops out while a query is
    /// active: it has no transcript and no title of its own yet, so it cannot match, and leaving it
    /// in would put a row in the results the query says nothing about.
    private func applyingSearchQuery(to items: [SessionListItem]) -> [SessionListItem] {
        guard let query = activeSearchQuery else { return items }
        return items.filter { Self.matches(query: query, item: $0) != nil }
    }

    /// How an item matched a query, or `nil` when it did not.
    ///
    /// A session can match on both; the transcript wins, because that is the match a snippet can be
    /// built from.
    static func matches(query: String, item: SessionListItem) -> SessionSearchMatchKind? {
        switch item {
        case .pending:
            return nil
        case .recording(let session):
            return matches(query: query, title: session.title, searchableText: session.searchableText)
        case .imported(let session):
            return matches(query: query, title: session.title, searchableText: session.searchableText)
        }
    }

    private static func matches(
        query: String,
        title: String,
        searchableText: String?
    ) -> SessionSearchMatchKind? {
        if searchableText?.localizedStandardContains(query) == true {
            return .transcript
        }
        if title.localizedStandardContains(query) {
            return .title
        }
        return nil
    }

    /// Where the query matched inside each transcript result, keyed by list item id.
    ///
    /// Stage two of the search, and the expensive half: it decodes transcripts. Only sessions that
    /// survived narrowing are in here, and only after the query has settled.
    private(set) var searchMatches: [String: SessionSearchMatch] = [:]

    /// How long the query must hold still before transcripts are decoded.
    ///
    /// Narrowing runs per keystroke — it reads a stored string. Locating does not: every keystroke
    /// would decode every surviving transcript again.
    static let searchMatchDebounce: Duration = .milliseconds(200)

    /// Recomputes `searchMatches` for the current query once it settles.
    ///
    /// Cancellable by design: called from a `.task(id:)` that restarts on every keystroke, so an
    /// in-flight debounce is discarded rather than decoding for a query the user has moved past.
    func updateSearchMatches(
        for items: [SessionListItem],
        debounce: Duration = JobsViewModel.searchMatchDebounce
    ) async {
        guard let query = activeSearchQuery else {
            searchMatches = [:]
            return
        }

        try? await Task.sleep(for: debounce)
        guard !Task.isCancelled else { return }

        searchMatches = Self.searchMatches(query: query, items: items)
    }

    /// Decodes the transcript of every item that matched on transcript text, and locates the query
    /// in it. Title-only matches are absent, which is what leaves their rows without a snippet.
    static func searchMatches(query: String, items: [SessionListItem]) -> [String: SessionSearchMatch] {
        var located: [String: SessionSearchMatch] = [:]
        for item in items where matches(query: query, item: item) == .transcript {
            guard let transcript = displayedTranscript(for: item),
                  let match = SessionSearchSnippetBuilder.match(query: query, in: transcript) else {
                continue
            }
            located[item.id] = match
        }
        return located
    }

    /// The pass a session displays, for the items the list is built from.
    ///
    /// The same `retranscript ?? transcript` the study view opens with — the snippet has to come
    /// from the text the user will see there, or the match would not be found again.
    static func displayedTranscript(for item: SessionListItem) -> Transcript? {
        switch item {
        case .pending:
            return nil
        case .recording(let session):
            return session.retranscript ?? session.transcript
        case .imported(let session):
            return session.retranscript ?? session.transcript
        }
    }

    /// Tags whose chips are lit. Empty means unfiltered.
    ///
    /// Held here alongside the item construction it affects, rather than in a separate filtering
    /// layer, because the list is already composed in memory from `@Query` results — there is no
    /// fetch predicate to push this into.
    var selectedTagIDs: Set<UUID> = []

    func toggleTagFilter(_ tagID: UUID) {
        if selectedTagIDs.contains(tagID) {
            selectedTagIDs.remove(tagID)
        } else {
            selectedTagIDs.insert(tagID)
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

        let sessionID = session.id
        let modelContainer = context.container
        let pipelineSettings = currentPipelineSettings

        Task {
            do {
                let workspace = try await workspaceService.requireWritableWorkspace()
                let transcript = try await transcriptionService.transcribe(
                    sessionID: sessionID,
                    modelContainer: modelContainer,
                    workspace: workspace,
                    pipelineSettings: pipelineSettings
                )
                
                // Update session on MainActor since JobsViewModel is @MainActor
                // and session is a SwiftData model.
                // We need to fetch it again or use the one we have if it's safe.
                // Since we are in a @MainActor Task, we can use the original session if it's still valid.
                
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

    /// Deletes a recording and everything it produced.
    ///
    /// The whole folder goes, not a list of known file names. That list has grown twice already —
    /// `.timing` sidecars, then trim backups — and each addition would have leaked silently until
    /// somebody remembered to extend it. Removing the container has no such failure mode.
    ///
    /// The record is deleted even when the folder cannot be, so a session never becomes
    /// undeletable because of something wrong with its path.
    func delete(session: RecordingSession, context: ModelContext) async {
        let folder = URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
        await removeSessionFolder(folder)
        context.delete(session)
        try? context.save()
    }

    /// Removes a session's folder, if it is one this application is allowed to remove.
    ///
    /// A refusal is not a failure of the delete: the caller still drops the record. A session whose
    /// stored path is wrong should stop appearing in the list, not become permanent.
    private func removeSessionFolder(_ folder: URL) async {
        guard let workspace = await workspaceService.currentWorkspace() else {
            logger.error("Refusing to remove a session folder with no workspace available.")
            return
        }
        guard Self.isRemovableSessionFolder(folder, in: workspace) else {
            logger.error(
                "Refusing to remove a session folder outside the workspace: \(folder.path, privacy: .public)"
            )
            return
        }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch CocoaError.fileNoSuchFile {
            // Already gone. Nothing to report.
        } catch {
            logger.error(
                "Failed to remove session folder \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Whether `folder` sits strictly inside one of the workspace areas sessions live in.
    ///
    /// This exists because the input is a path from the store and the operation is a recursive
    /// directory delete. A truncated or hand-edited path could resolve its parent to the workspace
    /// root, a home directory, or `/`. Paths are standardised and symlink-resolved first, so `..`
    /// segments and symlinks cannot step outside a prefix that merely matches textually.
    ///
    /// The area roots themselves are excluded: `recordings/` is never a session folder, and
    /// removing it would take every session with it.
    static func isRemovableSessionFolder(_ folder: URL, in workspace: Workspace) -> Bool {
        let resolved = folder.standardizedFileURL.resolvingSymlinksInPath()
        return [workspace.recordingsURL, workspace.importsURL].contains { root in
            let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved != resolvedRoot else { return false }
            return resolved.path.hasPrefix(resolvedRoot.path + "/")
        }
    }

    func importAudio(urls: [URL], context: ModelContext) async {
        let audioURLs = urls.filter { Self.isAudioURL($0) }
        guard !audioURLs.isEmpty else {
            return
        }

        do {
            let workspace = try await workspaceService.requireWritableWorkspace()
            let modelContainer = context.container
            let pipelineSettings = currentPipelineSettings
            for audioURL in audioURLs {
                await audioImportService.importAudio(
                    from: audioURL,
                    workspace: workspace,
                    modelContainer: modelContainer,
                    pipelineSettings: pipelineSettings
                )
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

        let sessionID = session.id
        let modelContainer = context.container
        let pipelineSettings = currentPipelineSettings

        Task {
            do {
                let workspace = try await workspaceService.requireWritableWorkspace()
                await retranscriptionService.retranscribe(
                    sessionID: sessionID,
                    modelContainer: modelContainer,
                    workspace: workspace,
                    pipelineSettings: pipelineSettings
                )
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

        let sessionID = session.id
        let modelContainer = context.container
        let pipelineSettings = currentPipelineSettings

        Task {
            do {
                let workspace = try await workspaceService.requireWritableWorkspace()
                await retranscriptionService.retranscribe(
                    sessionID: sessionID,
                    modelContainer: modelContainer,
                    workspace: workspace,
                    pipelineSettings: pipelineSettings
                )
            } catch {
                session.status = .error(error.localizedDescription)
                session.errorMessage = error.localizedDescription
                try? context.save()
            }
        }
    }

    func exportTranscript(for session: any TranscribableSession) async throws {
        guard let transcript = displayedTranscript(for: session) else {
            throw TranscriptExportError.transcriptUnavailable
        }

        let markdown = markdownRenderer.renderMarkdown(session: session, transcript: transcript)
        let suggestedName = markdownRenderer.defaultFileName(for: session.title)

        guard let destinationURL = savePanelPresenter(suggestedName) else {
            return
        }

        try transcriptExportService.write(markdown, to: destinationURL)
    }

    /// Deletes an imported session and its folder.
    ///
    /// Unconditionally, where this previously removed the folder only when it happened to be empty
    /// afterwards. Two rules for two session types would be a distinction with nothing behind it,
    /// and the old one was not even conservative — an unexpected file quietly preserved a folder
    /// nobody would look in again.
    func deleteImported(session: ImportedSession, context: ModelContext) async {
        if let mixdownPath = session.mixdownURL {
            let folder = URL(fileURLWithPath: mixdownPath).deletingLastPathComponent()
            await removeSessionFolder(folder)
        }
        context.delete(session)
        try? context.save()
    }

    private func displayedTranscript(for session: any TranscribableSession) -> Transcript? {
        session.retranscript ?? session.transcript
    }

    private static func defaultSavePanelPresenter(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedName

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
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
