import SwiftUI

struct AppShellView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            StudioView(viewModel: appState.studioViewModel)
                .tag(AppState.Tab.studio)
                .tabItem {
                    Label("Studio", systemImage: "waveform")
                }

            JobsView(viewModel: appState.jobsViewModel)
                .tag(AppState.Tab.jobs)
                .tabItem {
                    Label("Jobs", systemImage: "list.bullet.rectangle")
                }

            SettingsView(viewModel: appState.settingsViewModel)
                .tag(AppState.Tab.settings)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .frame(minWidth: 900, minHeight: 600)
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
    }
}
