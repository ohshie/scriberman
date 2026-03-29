import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AppShellView: View {
    private enum DetailMode {
        case standard
        case study
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var recordingSessions: [RecordingSession]
    @Query(sort: \ImportedSession.createdAt, order: .reverse) private var importedSessions: [ImportedSession]
    @State private var selectedSession: JobsViewModel.SessionListItem?
    @State private var detailMode: DetailMode = .standard
    @State private var studyActionErrorMessage: String?

    private var allSessionItems: [JobsViewModel.SessionListItem] {
        let recordingItems = recordingSessions.map(JobsViewModel.SessionListItem.recording)
        let importedItems = importedSessions.map(JobsViewModel.SessionListItem.imported)
        return (recordingItems + importedItems).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationSplitView {
            JobsView(
                viewModel: appState.jobsViewModel,
                items: allSessionItems,
                selection: $selectedSession
            )
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 380, ideal: 460)
        } detail: {
            if let selectedSession {
                detailView(for: selectedSession)
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
        .sheet(isPresented: $appState.workspaceSelectionRequired) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Select Workspace Folder")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Scriberman stores models and jobs in your workspace. Recommended: ~/Documents/Scriberman")
                    .foregroundStyle(.secondary)

                if let errorMessage = appState.workspaceErrorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Choose Folder") {
                        Task {
                            guard let url = await MainActor.run(body: {
                                WorkspacePicker.chooseWorkspaceFolder()
                            }) else {
                                return
                            }

                            await appState.selectWorkspace(url: url)
                        }
                    }
                    .keyboardShortcut(.defaultAction)

                    Button("Later") {
                        appState.workspaceSelectionRequired = false
                    }
                }
            }
            .padding(24)
        }
        .sheet(
            isPresented: Binding(
                get: { appState.showPermissionsOnboarding && !appState.workspaceSelectionRequired },
                set: { appState.showPermissionsOnboarding = $0 }
            )
        ) {
            PermissionsOnboardingView(permissionService: appState.permissionService)
                .environmentObject(appState)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                return
            }

            Task {
                await appState.refreshPermissionsOnActivation()
            }
        }
        .onChange(of: selectedSession) { oldValue, newValue in
            guard oldValue?.id != newValue?.id else {
                return
            }
            detailMode = .standard
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
                    onTranscribe: { session in
                        appState.jobsViewModel.transcribe(session: session, context: modelContext)
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
                TranscriptStudyView(session: session, transcript: transcript)
            } else {
                TranscriptDetailView(
                    session: session,
                    onReprocess: {
                        appState.jobsViewModel.reprocess(session: session, context: modelContext)
                    },
                    onDelete: {
                        appState.jobsViewModel.delete(session: session, context: modelContext)
                        selectedSession = nil
                    },
                    onOpenStudy: {
                        detailMode = .study
                    }
                )
            }

        case .imported(let session):
            if detailMode == .study, let transcript = displayedTranscript(for: session) {
                TranscriptStudyView(session: session, transcript: transcript)
            } else {
                TranscriptDetailView(
                    session: session,
                    onReprocess: {
                        appState.jobsViewModel.reprocess(session: session, context: modelContext)
                    },
                    onDelete: {
                        appState.jobsViewModel.deleteImported(session: session, context: modelContext)
                        selectedSession = nil
                    },
                    onOpenStudy: {
                        detailMode = .study
                    }
                )
            }
        }
    }

    @Environment(\.modelContext) private var modelContext

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
                try await appState.services.transcriptExportService.export(
                    session: session,
                    transcript: displayedTranscript(for: session)
                )
            } catch TranscriptExportError.exportCancelled {
                return
            } catch {
                studyActionErrorMessage = error.localizedDescription
            }
        }
    }
}
