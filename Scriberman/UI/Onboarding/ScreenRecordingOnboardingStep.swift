import AppKit
import SwiftUI

struct ScreenRecordingOnboardingStep: View {
    @Environment(AppState.self) private var appState
    var onAdvance: () -> Void

    @State private var isVerifying = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Screen Recording Access")
                .font(.title2.weight(.semibold))

            Text("Scriberman needs Screen Recording permission to capture audio from other apps. After granting access in System Settings, restart Scriberman for the change to take effect.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(spacing: 10) {
                Button("Open System Settings") {
                    openSystemSettings()
                }
                .buttonStyle(.bordered)

                Button("Restart Scriberman") {
                    NSWorkspace.shared.open(Bundle.main.bundleURL)
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await verifyAndAdvanceIfGranted()
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
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await verifyAndAdvanceIfGranted()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func verifyAndAdvanceIfGranted() async {
        if appState.permissionService.screenRecordingStatus == .granted {
            onAdvance()
            return
        }

        guard !isVerifying else {
            return
        }

        isVerifying = true
        let granted = await appState.permissionService.verifyScreenRecording()
        isVerifying = false

        if granted {
            onAdvance()
        }
    }
}
