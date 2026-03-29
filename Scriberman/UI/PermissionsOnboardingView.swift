import AppKit
import SwiftUI

struct PermissionsOnboardingView: View {
    enum OnboardingStep {
        case mic
        case screenRecording
    }

    @EnvironmentObject private var appState: AppState
    @State private var currentStep: OnboardingStep = .mic
    @State private var micVerified = false
    @State private var screenRecordingVerified = false
    @State private var isVerifyingMic = false
    @State private var isVerifyingScreenRecording = false
    @State private var infoMessage: String?
    @State private var didAutoVerifyMic = false
    @State private var didAutoVerifyScreenRecording = false

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

            Divider()

            Button("Skip All") {
                skipAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(24)
        .frame(minWidth: 520)
        .interactiveDismissDisabled(!allStepsVerified)
        .onAppear {
            guard !didAutoVerifyMic else {
                return
            }
            didAutoVerifyMic = true
            Task { @MainActor in
                await autoVerifyMicIfPossible()
            }
        }
        .onChange(of: currentStep) { _, newStep in
            guard newStep == .screenRecording else {
                return
            }
            guard !didAutoVerifyScreenRecording else {
                return
            }
            didAutoVerifyScreenRecording = true
            Task { @MainActor in
                await autoVerifyScreenRecordingIfPossible()
            }
        }
    }

    private var progressIndicator: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentStep == .mic ? "1 of 2" : "2 of 2")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                stepStatusLabel(
                    title: "Microphone",
                    verified: micVerified
                )

                stepStatusLabel(
                    title: "Screen Recording",
                    verified: screenRecordingVerified,
                    locked: !micVerified
                )
            }
        }
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
                        await verifyMicAndAdvance()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isVerifyingMic)

                Button("Verify") {
                    Task { @MainActor in
                        await verifyMicAndAdvance()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isVerifyingMic)
            }

            if isVerifyingMic {
                ProgressView("Verifying Microphone access...")
                    .font(.footnote)
            }

            if !micVerified {
                Text("Step 2 is locked until microphone access is verified.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let infoMessage {
                Text(infoMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    infoMessage = "Allow access in System Settings, then click Verify."
                }
                .buttonStyle(.borderedProminent)
                .disabled(isVerifyingScreenRecording)

                Button("Verify") {
                    Task { @MainActor in
                        await verifyScreenRecordingAndDismissIfNeeded()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isVerifyingScreenRecording)
            }

            Button("Open System Settings") {
                openScreenRecordingSettings()
            }
            .buttonStyle(.bordered)

            if isVerifyingScreenRecording {
                ProgressView("Verifying Screen Recording access...")
                    .font(.footnote)
            }

            if let infoMessage {
                Text(infoMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var allStepsVerified: Bool {
        micVerified && screenRecordingVerified
    }

    private func dismissOnboarding() {
        permissionService.markOnboardingShown()
        appState.showPermissionsOnboarding = false
    }

    private func skipAll() {
        infoMessage = nil
        dismissOnboarding()
    }

    private func autoVerifyMicIfPossible() async {
        await verifyMicAndAdvance(showFailureMessage: false)
    }

    private func autoVerifyScreenRecordingIfPossible() async {
        guard micVerified else {
            return
        }
        await verifyScreenRecordingAndDismissIfNeeded(showFailureMessage: false)
    }

    private func verifyMicAndAdvance(showFailureMessage: Bool = true) async {
        isVerifyingMic = true
        defer { isVerifyingMic = false }

        let verified = await permissionService.verifyMic()
        micVerified = verified

        if verified {
            infoMessage = nil
            currentStep = .screenRecording
        } else if showFailureMessage {
            infoMessage = "Microphone access is still not granted. Allow access in System Settings, then Verify again."
        }
    }

    private func verifyScreenRecordingAndDismissIfNeeded(showFailureMessage: Bool = true) async {
        isVerifyingScreenRecording = true
        defer { isVerifyingScreenRecording = false }

        let verified = await permissionService.verifyScreenRecording()
        screenRecordingVerified = verified

        if verified {
            infoMessage = nil
            dismissOnboarding()
        } else if showFailureMessage {
            infoMessage = "Screen Recording verification failed. Ensure access is enabled, then Verify again."
        }
    }

    @ViewBuilder
    private func stepStatusLabel(title: String, verified: Bool, locked: Bool = false) -> some View {
        Label {
            Text(title)
                .font(.caption)
        } icon: {
            if verified {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if locked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
