import AppKit
import SwiftUI

struct ScreenRecordingOnboardingStep: View {
    @Environment(AppState.self) private var appState
    var onAdvance: () -> Void

    @State private var isVerifying = false
    @State private var hasAttemptedAutomaticRequest = false
    @State private var verificationMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Screen Recording Access")
                .font(.title2.weight(.semibold))

            Text("Scriberman needs Screen Recording permission to capture audio from other apps.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(spacing: 10) {
                Button("Open System Settings") {
                    openSystemSettings()
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await verifyAndAdvanceIfGranted(showFeedback: true)
                    }
                } label: {
                    if isVerifying {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Text("Verify")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isVerifying)

                if let verificationMessage {
                    Text(verificationMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await autoRequestAndAdvanceIfNeeded()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func verifyAndAdvanceIfGranted(showFeedback: Bool) async {
        if appState.permissionService.screenRecordingStatus == .granted {
            if showFeedback {
                verificationMessage = "Screen Recording access is granted. Please restart Scriberman to continue."
            }
            onAdvance()
            return
        }

        guard !isVerifying else {
            return
        }

        if showFeedback {
            verificationMessage = "Checking Screen Recording access..."
        }

        isVerifying = true
        let granted = await appState.permissionService.verifyScreenRecording()
        isVerifying = false

        if granted {
            if showFeedback {
                verificationMessage = "Screen Recording access is granted. Please restart Scriberman to continue."
            }
            onAdvance()
        } else if showFeedback {
            verificationMessage = "Access is still blocked. Enable Screen Recording in System Settings, then restart Scriberman and press Verify again."
        }
    }

    private func autoRequestAndAdvanceIfNeeded() async {
        guard !hasAttemptedAutomaticRequest else {
            return
        }

        hasAttemptedAutomaticRequest = true

        if appState.permissionService.screenRecordingStatus == .notDetermined {
            _ = appState.permissionService.requestScreenRecording()
        }

        await verifyAndAdvanceIfGranted(showFeedback: false)
    }
}
