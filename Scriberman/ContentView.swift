import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if appState.isBootstrapping {
                Color.clear
            } else if appState.requiredOnboardingStep != nil {
                OnboardingView()
                    .frame(width: 560, height: 500)
            } else {
                AppShellView()
            }
        }
        .onAppear {
            appState.openSettingsAction = { openSettings() }
        }
        .onChange(of: appState.requiredOnboardingStep) { _, _ in
            appState.applyReadiness()
        }
        .onChange(of: appState.workspace) { _, _ in
            appState.applyReadiness()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
