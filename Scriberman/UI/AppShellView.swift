import AppKit
import Combine
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AppShellView: View {
    private enum DetailMode {
        case standard
        case study
        case transformation
    }

    @Environment(AppState.self) private var appState
    @Environment(AIProviderService.self) private var aiProviderService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var controlActiveState
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var recordingSessions: [RecordingSession]
    @Query(sort: \ImportedSession.createdAt, order: .reverse) private var importedSessions: [ImportedSession]
    @State private var selectedSession: JobsViewModel.SessionListItem?
    @State private var detailMode: DetailMode = .standard
    @State private var selectedTransformationID: UUID?
    @State private var studyActionErrorMessage: String?
    /// A store or disk failure from deleting, importing, stopping or renaming, waiting to be shown.
    @State private var storeFailureAlert: StoreFailureAlert?
    @State private var audioPlayerViewModel = AudioPlayerViewModel()
    @State private var transcriptAutoScrollEnabled = true
    /// The search to open the study view with, set when a search result is clicked and cleared on
    /// any other navigation.
    @State private var studySearchSeed: TranscriptStudySearchSeed?
    /// Which item the seed belongs to. Selecting a result changes the selection, and the change
    /// handler would otherwise clear the seed it was just given and send the view back to the
    /// standard detail.
    @State private var studySearchSeedItemID: String?
    /// Bumped to ask the sidebar's search field for focus. The window owns the find shortcut, so
    /// there is one place that decides what ⌘F means at any moment.
    @State private var searchFocusRequest = 0
    /// Bumped to ask the study view to open its find bar.
    @State private var transcriptFindRequest = 0
    @State private var textEditingObserver = TextEditingObserver()
    @FocusState private var isSessionListFocused: Bool

    var body: some View {
        NavigationSplitView {
            JobsView(
                viewModel: appState.jobsViewModel,
                items: appState.jobsViewModel.sessionItems(
                    recordingSessions: recordingSessions,
                    importedSessions: importedSessions,
                    preserving: selectedSession
                ),
                pendingSession: appState.pendingSession,
                totalSessionCount: recordingSessions.count + importedSessions.count,
                isNewSessionIdle: appState.newSessionViewModel.isIdle,
                selection: $selectedSession,
                onDiscardPendingSession: { appState.discardPendingSession() },
                searchFocusRequest: searchFocusRequest,
                onSearchEscape: { isSessionListFocused = true },
                onOpenSearchResult: { item in openSearchResult(item) }
            )
            .focused($isSessionListFocused)
            .navigationSplitViewColumnWidth(min: 380, ideal: 460)
        } detail: {
            if let selectedSession {
                detailView(for: selectedSession)
                    .safeAreaBar(edge: .bottom, spacing: 0) {
                        AudioPlayerBar(
                            viewModel: audioPlayerViewModel,
                            sessionHasAudio: audioURL(for: selectedSession) != nil || selectedSessionHasMixdownNil(selectedSession),
                            mixdownURL: mixdownURLString(for: selectedSession),
                            onResumeScroll: transcriptAutoScrollEnabled ? nil : {
                                transcriptAutoScrollEnabled = true
                            }
                        )
                    }
                    .navigationSplitViewColumnWidth(min: 560, ideal: 860)
            } else {
                ContentUnavailableView(
                    "Select a Session",
                    systemImage: "text.bubble",
                    description: Text("Choose a session from the list to see its transcript and details.")
                ).navigationSplitViewColumnWidth(min: 560, ideal: 860)
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        // Sets the window's title, which Mission Control, the Window menu and the window switcher
        // show. Removing the toolbar's title item below hides it from the toolbar only, so the editable
        // header title stays the one visible title.
        .navigationTitle(Self.windowTitle(for: selectedSession))
        .toolbar {
            switch detailMode {
            case .standard:
                jobsToolbar
            case .study:
                studyModeToolbar
            case .transformation:
                transformationModeToolbar
            }
        }
        .toolbar(removing: .title)
        .toolbar(removing: .search)
        .frame(minHeight: 580)
        .alert("Study Action Failed", isPresented: Binding(
            get: { studyActionErrorMessage != nil },
            set: { isPresented in
                if isPresented == false {
                    studyActionErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(studyActionErrorMessage ?? "Unknown error.")
        }
        .alert(
            storeFailureAlert?.title ?? "",
            isPresented: Binding(
                get: { storeFailureAlert != nil },
                set: { if !$0 { dismissStoreFailureAlert() } }
            ),
            presenting: storeFailureAlert
        ) { _ in
            Button("OK", role: .cancel) { }
        } message: { alert in
            Text(alert.message)
        }
        .onChange(of: appState.newSessionViewModel.unsavedTranscriptSegmentCount) { _, count in
            if count > 0 {
                storeFailureAlert = .transcriptNotSaved(count)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.sessionToTrim != nil },
            set: { if !$0 { appState.sessionToTrim = nil } }
        )) {
            if let session = appState.sessionToTrim {
                TrimEditorView(
                    viewModel: TrimEditorViewModel(session: session, audioPlayer: audioPlayerViewModel, context: modelContext),
                    onDismiss: { appState.sessionToTrim = nil }
                )
            }
        }
        .focusedSceneValue(\.mainWindow, commandContext)
        .background {
            WindowReader { window in
                textEditingObserver.observe(window)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                return
            }

            Task {
                await appState.refreshPermissionsOnActivation()
            }
            Task {
                await appState.calendarSuggestions.refresh()
            }
        }

        .onChange(of: selectedSession) { oldValue, newValue in
            guard oldValue?.id != newValue?.id else {
                return
            }

            // A selection made by opening a search result arrives here carrying its seed. Resetting
            // to the standard detail then would undo the navigation that caused this change.
            let isOpeningSearchResult = newValue != nil && newValue?.id == studySearchSeedItemID

            transcriptAutoScrollEnabled = true
            audioPlayerViewModel.stop()
            if let url = audioURL(for: newValue) {
                audioPlayerViewModel.load(url: url)
            } else {
                audioPlayerViewModel.clear()
            }

            selectedTransformationID = nil
            guard !isOpeningSearchResult else { return }

            studySearchSeed = nil
            studySearchSeedItemID = nil
            detailMode = .standard
        }
        .onChange(of: detailMode) { _, newValue in
            if newValue != .study {
                transcriptAutoScrollEnabled = true
            }
        }
        // A request from outside any window is shown by the key main window. Each of these is a
        // moment the request may have become showable: it arrived, this window became key, or the
        // session it names reached this window's query.
        .onAppear { showRequestedSession() }
        .onChange(of: appState.sessionRequest) { showRequestedSession() }
        .onChange(of: controlActiveState) { showRequestedSession() }
        .onChange(of: recordingSessions.map(\.id)) { showRequestedSession() }
        .onChange(of: appState.pendingSession?.id) { showRequestedSession() }
    }

    private func showRequestedSession() {
        guard controlActiveState == .key else {
            return
        }

        let request = appState.consumeSessionRequest { request in
            sessionItem(for: request) != nil
        }
        if let request, let item = sessionItem(for: request) {
            selectedSession = item
        }
    }

    /// The selected session's title, or "Sessions" when nothing is selected or a new session is
    /// being set up. Reading the title here makes the window follow a rename.
    static func windowTitle(for item: JobsViewModel.SessionListItem?) -> String {
        let title: String
        switch item {
        case .recording(let session):
            title = session.title
        case .imported(let session):
            title = session.title
        case .pending, nil:
            title = ""
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Sessions" : trimmed
    }

    private func sessionItem(for request: AppState.SessionRequest) -> JobsViewModel.SessionListItem? {
        switch request {
        case .pending:
            return appState.pendingSession.map { .pending($0) }
        case .recording(let sessionID):
            return recordingSessions.first { $0.id == sessionID }.map { .recording($0) }
        }
    }

    @ViewBuilder
    private func detailView(for item: JobsViewModel.SessionListItem) -> some View {
        switch item {
        case .pending(let pendingItem):
            if let pendingSession = appState.pendingSession, pendingSession.id == pendingItem.id {
                NewSessionPanelView(
                    viewModel: appState.newSessionViewModel,
                    pendingSession: Binding(
                        get: { appState.pendingSession ?? pendingSession },
                        set: { appState.pendingSession = $0 }
                    ),
                    onRecordingStarted: { session in
                        appState.discardPendingSession()
                        selectedSession = .recording(session)
                    },
                    onImportFile: {
                        presentImportPanel()
                    }
                )
            } else {
                ContentUnavailableView(
                    "No Pending Session",
                    systemImage: "plus.circle",
                    description: Text("Create a new session from the + button.")
                )
            }
        case .recording(let session):
            if session.status == .recording {
                ActiveRecordingDetailView(
                    session: session,
                    viewModel: appState.newSessionViewModel,
                    modelContext: modelContext,
                    onTitleNotSaved: { storeFailureAlert = .titleNotSaved }
                )
                .id(session.id)
            } else if detailMode == .study, let transcript = session.displayedTranscript {
                TranscriptStudyView(
                    session: session,
                    aiProviderService: aiProviderService,
                    audioPlayerViewModel: audioPlayerViewModel,
                    autoScrollEnabled: $transcriptAutoScrollEnabled,
                    transcript: transcript,
                    store: appState.backgroundServices.speakerEmbeddingStore,
                    searchSeed: studySearchSeed,
                    findRequest: transcriptFindRequest
                )
                .id(session.id)
            } else if detailMode == .transformation {
                AITransformationDetailView(
                    session: session,
                    aiProviderService: aiProviderService,
                    selectedTransformationID: $selectedTransformationID
                )
            } else {
                TranscriptDetailView(
                    session: session,
                    aiProviderService: aiProviderService,
                    onReprocess: {
                        appState.jobsViewModel.reprocess(session: session, context: modelContext)
                    },
                    onCopy: {
                        copyTranscript(for: session)
                    },
                    onDelete: {
                        let item = selectedSession
                        selectedSession = nil
                        Task {
                            let result = await appState.jobsViewModel.delete(session: session, context: modelContext)
                            handleDeletion(result, of: item)
                        }
                    },
                    onRestoreOriginal: {
                        try await restoreOriginal(of: session)
                    },
                    onOpenStudy: {
                        detailMode = .study
                    },
                    onOpenTransformation: { transformationID in
                        selectedTransformationID = transformationID
                        detailMode = .transformation
                    },
                    onTitleNotSaved: { storeFailureAlert = .titleNotSaved }
                )
                .id(session.id)
            }

        case .imported(let session):
            if detailMode == .study, let transcript = session.displayedTranscript {
                TranscriptStudyView(
                    session: session,
                    aiProviderService: aiProviderService,
                    audioPlayerViewModel: audioPlayerViewModel,
                    autoScrollEnabled: $transcriptAutoScrollEnabled,
                    transcript: transcript,
                    store: appState.backgroundServices.speakerEmbeddingStore,
                    searchSeed: studySearchSeed,
                    findRequest: transcriptFindRequest
                )
                .id(session.id)
            } else if detailMode == .transformation {
                AITransformationDetailView(
                    session: session,
                    aiProviderService: aiProviderService,
                    selectedTransformationID: $selectedTransformationID
                )
            } else {
                TranscriptDetailView(
                    session: session,
                    aiProviderService: aiProviderService,
                    onReprocess: {
                        appState.jobsViewModel.reprocess(session: session, context: modelContext)
                    },
                    onCopy: {
                        copyTranscript(for: session)
                    },
                    onDelete: {
                        let item = selectedSession
                        selectedSession = nil
                        Task {
                            let result = await appState.jobsViewModel.deleteImported(session: session, context: modelContext)
                            handleDeletion(result, of: item)
                        }
                    },
                    onOpenStudy: {
                        detailMode = .study
                    },
                    onOpenTransformation: { transformationID in
                        selectedTransformationID = transformationID
                        detailMode = .transformation
                    },
                    onTitleNotSaved: { storeFailureAlert = .titleNotSaved }
                )
                .id(session.id)
            }
        }
    }

    @Environment(\.modelContext) private var modelContext

    /// Reports a deletion. A failed save leaves the session in place, so its row is selected again.
    private func handleDeletion(_ result: JobsViewModel.DeletionResult, of item: JobsViewModel.SessionListItem?) {
        switch result {
        case .deleted:
            break
        case .saveFailed(let reason):
            selectedSession = item
            storeFailureAlert = .deletionFailed(reason)
        case .filesLeft(let folder):
            storeFailureAlert = .filesLeft(folder.path)
        }
    }

    private func dismissStoreFailureAlert() {
        if case .transcriptNotSaved = storeFailureAlert {
            appState.newSessionViewModel.unsavedTranscriptSegmentCount = 0
        }
        storeFailureAlert = nil
    }

    private func restoreOriginal(of session: RecordingSession) async throws {
        audioPlayerViewModel.stop()
        try await AudioTrimService().restore(session: session, context: modelContext)
        audioPlayerViewModel.reload()
    }

    private func audioURL(for item: JobsViewModel.SessionListItem?) -> URL? {
        guard let item else {
            return nil
        }

        switch item {
        case .pending:
            return nil
        case .recording(let session):
            guard let mixdownURL = session.mixdownURL, mixdownURL.isEmpty == false else {
                return nil
            }
            return URL(fileURLWithPath: mixdownURL)
        case .imported(let session):
            guard let mixdownURL = session.mixdownURL, mixdownURL.isEmpty == false else {
                return nil
            }
            return URL(fileURLWithPath: mixdownURL)
        }
    }

    private func mixdownURLString(for item: JobsViewModel.SessionListItem?) -> String? {
        switch item {
        case .recording(let session):
            return session.mixdownURL
        case .imported(let session):
            return session.mixdownURL
        case .pending, .none:
            return nil
        }
    }

    private func selectedSessionHasMixdownNil(_ item: JobsViewModel.SessionListItem?) -> Bool {
        switch item {
        case .recording(let session):
            return session.mixdownURL == nil && session.status != .done
        case .imported(let session):
            return session.mixdownURL == nil && session.status != .done
        case .pending, .none:
            return false
        }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]

        Task {
            guard await runAttachedToWindow(panel) == .OK else {
                return
            }
            let failed = await appState.jobsViewModel.importAudio(urls: panel.urls, context: modelContext)
            appState.discardPendingSession()
            if !failed.isEmpty {
                storeFailureAlert = .importFailed(failed.map(\.lastPathComponent))
            }
        }
    }

    /// The New Session (+) button is redundant while the New Session panel or an
    /// in-progress recording is on screen, so it is hidden in those contexts.
    private var hideNewSessionButton: Bool {
        guard let selectedSession else { return false }
        switch selectedSession {
        case .pending:
            return true
        case .recording(let session):
            return session.status == .recording
        case .imported:
            return false
        }
    }

    @ToolbarContentBuilder
    private var jobsToolbar: some ToolbarContent {
        if !hideNewSessionButton {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startNewSession()
                } label: {
                    Label("New Session", systemImage: "plus")
                }
            }
        }
    }

    private func startNewSession() {
        appState.selectPendingSession()
        appState.newSessionViewModel.refreshAudioDevicesOnPanelExpanded()
        if let pendingSession = appState.pendingSession {
            selectedSession = .pending(pendingSession)
        }
    }

    /// This window's selection and actions, published to the menu bar while the window is focused.
    private var commandContext: MainWindowCommandContext {
        MainWindowCommandContext(
            selection: selectedSession,
            availability: SessionCommandAvailability(
                selection: commandSelection,
                isRecordingRunning: !appState.newSessionViewModel.isIdle,
                isTranscriptShown: isTranscriptShown,
                hasLoadedAudio: audioPlayerViewModel.isReady,
                // The session search field is always in the window, so Find always has a target.
                hasFindTarget: true
            ),
            isPlaying: audioPlayerViewModel.isPlaying,
            isEditingText: textEditingObserver.isEditingText,
            actions: MainWindowActions(
                newSession: { startNewSession() },
                importFile: { presentImportPanel() },
                startRecording: { startRecording() },
                stopRecording: { stopRecording() },
                playPause: { togglePlayback() },
                find: { find() }
            )
        )
    }

    /// Records the way the new-session panel's Record button does: into the pending session, which
    /// is created first when there is none. When recording cannot start yet, the panel stays shown
    /// so its controls say why.
    private func startRecording() {
        startNewSession()
        let viewModel = appState.newSessionViewModel
        guard viewModel.canRecord, let pendingSession = appState.pendingSession else {
            return
        }

        Task {
            if let session = await viewModel.startRecording(title: pendingSession.title, context: modelContext) {
                appState.discardPendingSession()
                selectedSession = .recording(session)
            }
        }
    }

    private func stopRecording() {
        Task {
            _ = await appState.newSessionViewModel.stopRecording(context: modelContext)
        }
    }

    private func togglePlayback() {
        if audioPlayerViewModel.isPlaying {
            audioPlayerViewModel.pause()
        } else {
            audioPlayerViewModel.play()
        }
    }

    /// With a transcript open, Find searches it: that is the text you came to read. Otherwise the
    /// session list is the only thing there is to search.
    private func find() {
        switch FindDestination(isTranscriptViewShown: detailMode == .study) {
        case .transcriptFindBar:
            transcriptFindRequest += 1
        case .sessionSearch:
            searchFocusRequest += 1
        }
    }

    private var commandSelection: SessionCommandAvailability.Selection {
        switch selectedSession {
        case .none:
            return .none
        case .pending:
            return .pending
        case .recording(let session):
            return .recording(session.status, isTrimmed: session.isTrimmed)
        case .imported(let session):
            return .imported(session.status)
        }
    }

    /// The detail shows a transcript: the standard detail or the study view, not a transformation
    /// and not a recording in progress.
    private var isTranscriptShown: Bool {
        guard detailMode != .transformation,
              let session = selectedTranscribableSession,
              session.status != .recording else {
            return false
        }
        return session.displayedTranscript != nil
    }

    @ToolbarContentBuilder
    private var studyModeToolbar: some ToolbarContent {
        if let session = selectedTranscribableSession {
            ToolbarItem(placement: .navigation) {
                Button {
                    detailMode = .standard
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
            }

            TranscriptStudyView.toolbarActions(
                onCopy: {
                    copyTranscript(for: session)
                },
                onExport: {
                    exportTranscript(for: session)
                },
                onFind: {
                    find()
                }
            )
        }
    }

    @ToolbarContentBuilder
    private var transformationModeToolbar: some ToolbarContent {
        if let session = selectedTranscribableSession {
            ToolbarItem(placement: .navigation) {
                Button {
                    detailMode = .standard
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
            }

            AITransformationDetailView.toolbarActions(
                onCopy: {
                    copyTransformation(for: session)
                },
                onExport: {
                    exportTransformation(for: session)
                }
            )
        }
    }

    private var selectedTranscribableSession: (any TranscribableSession)? {
        guard let selectedSession else {
            return nil
        }

        switch selectedSession {
        case .recording(let session):
            return session
        case .imported(let session):
            return session
        case .pending:
            return nil
        }
    }

    /// Opens a search result: the study view, with the query applied and the matched block
    /// selected, so it scrolls there and highlights it.
    ///
    /// A title-only result has no match to seed, so it opens the session as any other selection
    /// would. Nothing here starts playback.
    private func openSearchResult(_ item: JobsViewModel.SessionListItem) {
        guard let query = appState.jobsViewModel.activeSearchQuery else { return }

        // The seed is set before the selection, so the selection's change handler already sees
        // which item it belongs to.
        guard let match = appState.jobsViewModel.searchMatches[item.id] else {
            studySearchSeed = nil
            studySearchSeedItemID = nil
            selectedSession = item
            detailMode = .standard
            return
        }

        studySearchSeedItemID = item.id
        studySearchSeed = TranscriptStudySearchSeed(query: query, blockID: match.blockID)
        selectedSession = item
        detailMode = .study
    }

    /// Copies the transcript as the export writes it — the same rendering, speakers and times
    /// included.
    ///
    /// It used to copy `transcript.fullText`: the words with nothing around them. Two actions beside
    /// each other in one toolbar, apparently doing the same thing to the same transcript, quietly
    /// yielding different text — a difference nobody could see until after they had pasted. A
    /// conversation between several people is barely usable without knowing who said what.
    ///
    /// The copy control on an individual block stays unattributed: its subject is a quotation, where
    /// the speaker and the time are what the quoter would delete.
    private func copyTranscript(for session: any TranscribableSession) {
        guard let markdown = appState.jobsViewModel.renderedTranscript(for: session) else {
            return
        }

        copyToPasteboard(markdown)
    }

    private func exportTranscript(for session: any TranscribableSession) {
        Task { @MainActor in
            do {
                try await appState.jobsViewModel.exportTranscript(for: session)
            } catch {
                studyActionErrorMessage = error.localizedDescription
            }
        }
    }

    private func availableTransformations(for session: any TranscribableSession) -> [AITransformation] {
        session.aiTransformations.sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func selectedTransformation(for session: any TranscribableSession) -> AITransformation? {
        let transformations = availableTransformations(for: session)

        if let selectedTransformationID,
           let selected = transformations.first(where: { $0.id == selectedTransformationID }) {
            return selected
        }

        return transformations.last
    }

    private func copyTransformation(for session: any TranscribableSession) {
        guard let transformation = selectedTransformation(for: session) else {
            return
        }

        copyToPasteboard(transformation.resultText)
    }

    private func exportTransformation(for session: any TranscribableSession) {
        guard let transformation = selectedTransformation(for: session) else {
            return
        }

        let suggestedName = MarkdownRenderer().defaultTransformationFileName(
            sessionTitle: session.title,
            promptName: transformation.promptName
        )
        Task { @MainActor in
            guard let destinationURL = await presentMarkdownSavePanel(title: "Export Transformation", suggestedName: suggestedName) else {
                return
            }

            do {
                try transformation.resultText.write(to: destinationURL, atomically: true, encoding: .utf8)
            } catch {
                studyActionErrorMessage = error.localizedDescription
            }
        }
    }
}

/// The failures where the store and the disk could disagree, as the user is told about them.
private enum StoreFailureAlert: Equatable {
    case deletionFailed(String)
    case filesLeft(String)
    case importFailed([String])
    case transcriptNotSaved(Int)
    case titleNotSaved

    var title: String {
        switch self {
        case .deletionFailed: "Deletion Failed"
        case .filesLeft: "Files Left on Disk"
        case .importFailed: "Import Failed"
        case .transcriptNotSaved: "Transcript Not Fully Saved"
        case .titleNotSaved: "Title Not Saved"
        }
    }

    var message: String {
        switch self {
        case .deletionFailed(let reason):
            "Scriberman could not save the change, so nothing was deleted. \(reason)"
        case .filesLeft(let path):
            "The session was deleted, but its folder could not be removed: \(path)"
        case .importFailed(let fileNames):
            "\(fileNames.joined(separator: ", ")) could not be added to your library. Try importing it again."
        case .transcriptNotSaved(let count):
            "\(count) transcript lines from this recording could not be saved. The audio is intact; you can reprocess it to rebuild the transcript."
        case .titleNotSaved:
            "The new title could not be saved, so the session keeps its previous title."
        }
    }
}

/// Reports the window this view is in, and again whenever it moves to another.
private struct WindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onWindowChange = onWindowChange
    }

    final class ReportingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}
