import SwiftUI

struct ModelsOnboardingStep: View {
    @Environment(AppState.self) private var appState
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Download AI Models")
                .font(.title2.weight(.semibold))

            Text("Download and prepare Scriberman’s AI models. This is a one-time setup before you can start transcribing.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            content

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if appState.settingsViewModel.bundlePhase == .allReady {
                onComplete()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.settingsViewModel.bundlePhase {
        case .idle:
            Button("Download Models") {
                Task {
                    await appState.settingsViewModel.downloadAllTapped()
                }
            }
            .buttonStyle(.borderedProminent)
        case .downloading(let label, let progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(maxWidth: 360)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .warmingUp:
            VStack(spacing: 8) {
                ProgressView()
                Text("Compiling models…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .allReady:
            Button("Continue →") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
        case .error(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)

                Button("Retry") {
                    Task {
                        await appState.settingsViewModel.downloadAllTapped()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
