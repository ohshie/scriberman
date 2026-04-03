import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    @ViewBuilder
    var body: some View {
        if appState.isBootstrapping {
            Color.clear
        } else if appState.requiredOnboardingStep != nil {
            OnboardingView()
                .frame(width: 560, height: 500)
        } else {
            AppShellView()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
