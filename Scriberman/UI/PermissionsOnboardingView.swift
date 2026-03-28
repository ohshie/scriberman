import AppKit
import SwiftUI

struct PermissionsOnboardingView: View {
    enum OnboardingStep {
        case mic
        case screenRecording
    }

    @EnvironmentObject private var appState: AppState
    @State private var currentStep: OnboardingStep = .mic

    private let permissionService: PermissionServiceProtocol

    init(permissionService: PermissionServiceProtocol) {
        self.permissionService = permissionService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            progressIndicator

            switch currentStep {
            case .mic:
                micStep
            case .screenRecording:
                screenRecordingStep
            }
        }
        .padding(24)
        .frame(minWidth: 520)
        .interactiveDismissDisabled(currentStep == .mic)
    }

    private var progressIndicator: some View {
        Text(currentStep == .mic ? "1 of 2" : "2 of 2")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var micStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text("Microphone Access")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Scriberman needs microphone access to record your voice.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Grant Access") {
                    Task { @MainActor in
                        _ = await permissionService.requestMic()
                        currentStep = .screenRecording
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Skip") {
                    currentStep = .screenRecording
                }
            }
        }
    }

    private var screenRecordingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            Text("App Audio Capture")
                .font(.title2)
                .fontWeight(.semibold)

            Text("To record audio from other apps, enable Screen Recording in System Settings.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Grant Access") {
                    _ = permissionService.requestScreenRecording()
                    dismissOnboarding()
                }
                .buttonStyle(.borderedProminent)

                Button("Not Now") {
                    dismissOnboarding()
                }
            }

            Button("Open System Settings") {
                openScreenRecordingSettings()
            }
            .buttonStyle(.bordered)
        }
    }

    private func dismissOnboarding() {
        permissionService.markOnboardingShown()
        appState.showPermissionsOnboarding = false
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
