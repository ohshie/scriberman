import SwiftData
import SwiftUI

struct AppShellView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var recordingSessions: [RecordingSession]
    @Query(sort: \ImportedSession.createdAt, order: .reverse) private var importedSessions: [ImportedSession]
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var selectedSession: JobsViewModel.SessionListItem?

    private var allSessionItems: [JobsViewModel.SessionListItem] {
        let recordingItems = recordingSessions.map(JobsViewModel.SessionListItem.recording)
        let importedItems = importedSessions.map(JobsViewModel.SessionListItem.imported)
        return (recordingItems + importedItems).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            JobsView(
                viewModel: appState.jobsViewModel,
                items: allSessionItems,
                selection: $selectedSession
            )
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
        .toolbar(removing: .sidebarToggle)
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
                    )
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
}
