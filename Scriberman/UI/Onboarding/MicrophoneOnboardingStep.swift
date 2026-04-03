import AppKit
import SwiftUI

struct MicrophoneOnboardingStep: View {
    @Environment(AppState.self) private var appState
    var onAdvance: () -> Void

    @State private var isRequesting = false
    @State private var hasAttemptedAutomaticRequest = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Microphone Access")
                .font(.title2.weight(.semibold))

            Text("Microphone permission is required to record your voice for transcription.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)

            Button {
                Task {
                    await requestAndVerifyMicrophone()
                }
            } label: {
                if isRequesting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Text("Grant Access")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequesting)

            if appState.permissionService.micStatus == .denied {
                Button("Open System Settings") {
                    openSystemSettings()
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await autoRequestAndAdvanceIfNeeded()
        }
    }

    private func requestAndVerifyMicrophone() async {
        guard !isRequesting else {
            return
        }

        isRequesting = true
        _ = await appState.permissionService.requestMic()
        let granted = await appState.permissionService.verifyMic()
        isRequesting = false

        if granted {
            onAdvance()
        }
    }

    private func autoRequestAndAdvanceIfNeeded() async {
        guard !hasAttemptedAutomaticRequest else {
            return
        }

        hasAttemptedAutomaticRequest = true

        if appState.permissionService.micStatus == .granted {
            onAdvance()
            return
        }

        if appState.permissionService.micStatus == .notDetermined {
            await requestAndVerifyMicrophone()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
