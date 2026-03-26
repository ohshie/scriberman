import SwiftUI

struct AppShellView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            StudioView(viewModel: appState.studioViewModel)
                .tabItem {
                    Label("Studio", systemImage: "waveform")
                }

            JobsView(viewModel: appState.jobsViewModel)
                .tabItem {
                    Label("Jobs", systemImage: "list.bullet.rectangle")
                }

            SettingsView(viewModel: appState.settingsViewModel)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
