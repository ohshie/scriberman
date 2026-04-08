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
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var recordingSessions: [RecordingSession]
    @Query(sort: \ImportedSession.createdAt, order: .reverse) private var importedSessions: [ImportedSession]
    @State private var selectedSession: JobsViewModel.SessionListItem?
    @State private var detailMode: DetailMode = .standard
    @State private var selectedTransformationID: UUID?
    @State private var studyActionErrorMessage: String?
    @State private var audioPlayerViewModel = AudioPlayerViewModel()
    @State private var transcriptAutoScrollEnabled = true

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
                isNewSessionIdle: appState.newSessionViewModel.isIdle,
                selection: $selectedSession,
                onDiscardPendingSession: { appState.discardPendingSession() }
            )
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 380, ideal: 460)
        } detail: {
            if let selectedSession {
                detailView(for: selectedSession)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
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
                    description: Text("Choose a session from the Jobs list to see its transcript and metadata.")
                ).navigationSplitViewColumnWidth(min: 560, ideal: 860)
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        .toolbar {
            sidebarToolbar
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
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                return
            }

            Task {
                await appState.refreshPermissionsOnActivation()
            }
            focusPendingSessionIfRequested()
        }
        .onChange(of: selectedSession) { oldValue, newValue in
            guard oldValue?.id != newValue?.id else {
                return
            }

            transcriptAutoScrollEnabled = true
            audioPlayerViewModel.stop()
            if let url = audioURL(for: newValue) {
                audioPlayerViewModel.load(url: url)
            } else {
                audioPlayerViewModel.clear()
            }

            detailMode = .standard
            selectedTransformationID = nil
        }
        .onChange(of: detailMode) { _, newValue in
            if newValue != .study {
                transcriptAutoScrollEnabled = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.focusPendingSessionNotification)) { _ in
            focusPendingSessionIfRequested()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.focusRecordingSessionNotification)) { notification in
            guard let sessionID = notification.userInfo?["sessionID"] as? UUID else {
                return
            }
            focusRecordingSession(sessionID: sessionID)
        }
    }

    private func focusPendingSessionIfRequested() {
        guard appState.consumePendingSessionFocusRequest() else {
            return
        }

        guard let pendingSession = appState.pendingSession else {
            return
        }

        selectedSession = .pending(pendingSession)
    }

    private func focusRecordingSession(sessionID: UUID) {
        guard let session = recordingSessions.first(where: { $0.id == sessionID }) else {
            return
        }

        selectedSession = .recording(session)
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
                    onRecordingFinished: { session in
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
            if detailMode == .study, let transcript = displayedTranscript(for: session) {
                TranscriptStudyView(
                    session: session,
                    audioPlayerViewModel: audioPlayerViewModel,
                    autoScrollEnabled: $transcriptAutoScrollEnabled,
                    transcript: transcript,
                    store: appState.backgroundServices.speakerEmbeddingStore
                )
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
                    onDelete: {
                        appState.jobsViewModel.delete(session: session, context: modelContext)
                        selectedSession = nil
                    },
                    onOpenStudy: {
                        detailMode = .study
                    },
                    onOpenTransformation: { transformationID in
                        selectedTransformationID = transformationID
                        detailMode = .transformation
                    }
                )
                .id(session.id)
            }

        case .imported(let session):
            if detailMode == .study, let transcript = displayedTranscript(for: session) {
                TranscriptStudyView(
                    session: session,
                    audioPlayerViewModel: audioPlayerViewModel,
                    autoScrollEnabled: $transcriptAutoScrollEnabled,
                    transcript: transcript,
                    store: appState.backgroundServices.speakerEmbeddingStore
                )
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
                    onDelete: {
                        appState.jobsViewModel.deleteImported(session: session, context: modelContext)
                        selectedSession = nil
                    },
                    onOpenStudy: {
                        detailMode = .study
                    },
                    onOpenTransformation: { transformationID in
                        selectedTransformationID = transformationID
                        detailMode = .transformation
                    }
                )
                .id(session.id)
            }
        }
    }

    @Environment(\.modelContext) private var modelContext

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
            return session.mixdownURL == nil
        case .imported(let session):
            return session.mixdownURL == nil
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

        guard panel.runModal() == .OK else {
            return
        }

        Task {
            await appState.jobsViewModel.importAudio(urls: panel.urls, context: modelContext)
            appState.discardPendingSession()
        }
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Sidebar")
        }
    }

    @ToolbarContentBuilder
    private var jobsToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                appState.selectPendingSession()
                appState.newSessionViewModel.refreshAudioDevicesOnPanelExpanded()
                if let pendingSession = appState.pendingSession {
                    selectedSession = .pending(pendingSession)
                }
            } label: {
                Label("New Session", systemImage: "plus")
            }
        }
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

    private func displayedTranscript(for session: any TranscribableSession) -> Transcript? {
        session.retranscript ?? session.transcript
    }

    private func copyTranscript(for session: any TranscribableSession) {
        guard let transcript = displayedTranscript(for: session) else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript.fullText, forType: .string)
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

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transformation.resultText, forType: .string)
    }

    private func exportTransformation(for session: any TranscribableSession) {
        guard let transformation = selectedTransformation(for: session) else {
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Transformation"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = defaultTransformationFileName(sessionTitle: session.title, promptName: transformation.promptName)

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try transformation.resultText.write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
            studyActionErrorMessage = error.localizedDescription
        }
    }

    private func defaultTransformationFileName(sessionTitle: String, promptName: String) -> String {
        let sanitizedSession = sessionTitle.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedPrompt = promptName.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSession = sanitizedSession.isEmpty ? "Session" : sanitizedSession
        let basePrompt = sanitizedPrompt.isEmpty ? "Transformation" : sanitizedPrompt
        return "\(baseSession) - \(basePrompt).md"
    }
}
