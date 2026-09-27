import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

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
