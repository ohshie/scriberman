import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AppShellView: View {
    private enum SidebarToggleLocation {
        case toolbar
        case sidebar
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var recordingSessions: [RecordingSession]
    @Query(sort: \ImportedSession.createdAt, order: .reverse) private var importedSessions: [ImportedSession]
    @State private var selectedSession: JobsViewModel.SessionListItem?
    @State private var sidebarToggleLocation: SidebarToggleLocation = .sidebar

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
                selection: $selectedSession,
                showsInlineSidebarToggle: sidebarToggleLocation == .sidebar,
                onInlineSidebarToggle: toggleSidebarFromSidebar
            )
            .toolbar(removing: .sidebarToggle)
        } detail: {
            if let selectedSession {
                detailView(for: selectedSession)
            } else {
                ContentUnavailableView(
                    "Select a Session",
                    systemImage: "text.bubble",
                    description: Text("Choose a session from the Jobs list to see its transcript and metadata.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            sidebarToolbar
            jobsToolbar
        }
        .toolbar(removing: .title)
        .toolbar(removing: .search)
        .frame(minWidth: 860, minHeight: 580)
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
            .frame(minWidth: 520)
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

            appState.permissionService.checkAll()
            appState.showPermissionsOnboarding = !appState.workspaceSelectionRequired && appState.permissionService.needsOnboarding
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
            TranscriptDetailView(
                session: session,
                onReprocess: {
                    appState.jobsViewModel.reprocess(session: session, context: modelContext)
                },
                onDelete: {
                    appState.jobsViewModel.delete(session: session, context: modelContext)
                    selectedSession = nil
                }
            )

        case .imported(let session):
            TranscriptDetailView(
                session: session,
                onReprocess: {
                    appState.jobsViewModel.reprocess(session: session, context: modelContext)
                },
                onDelete: {
                    appState.jobsViewModel.deleteImported(session: session, context: modelContext)
                    selectedSession = nil
                }
            )
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
        if sidebarToggleLocation == .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSidebarFromToolbar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Show Sidebar")
            }
        }
    }

    @ToolbarContentBuilder
    private var jobsToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                appState.selectPendingSession()
                if let pendingSession = appState.pendingSession {
                    selectedSession = .pending(pendingSession)
                }
            } label: {
                Label("New Session", systemImage: "plus")
            }
        }
    }

    private func toggleSidebarFromToolbar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.easeInOut(duration: 0.18)) {
                sidebarToggleLocation = .sidebar
            }
        }
    }

    private func toggleSidebarFromSidebar() {
        withAnimation(.easeInOut(duration: 0.12)) {
            sidebarToggleLocation = .toolbar
        }
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }

}
