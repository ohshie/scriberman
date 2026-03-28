import AppKit
import SwiftData
import SwiftUI

struct StudioView: View {
    @ObservedObject var viewModel: StudioViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 20) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            switch viewModel.recordingState {
            case .idle:
                VStack(spacing: 12) {
                    HStack {
                        microphonePicker
                        appPickerSection
                        Spacer()
                    }

                    Button("New Recording") {
                        Task { await viewModel.startRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

            case .recording(let duration, let level):
                VStack(spacing: 16) {
                    if let selectedDeviceName = viewModel.selectedDevice?.name {
                        Text(selectedDeviceName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let selectedAppName = viewModel.selectedApp?.name {
                        Text("App: \(selectedAppName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    WaveformView(level: .constant(level))
                    Text(durationText(duration))
                        .font(.title3)
                        .monospacedDigit()

                    Button("Stop") {
                        Task { await viewModel.stopRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

            case .stopped(_, let ctaSecondsRemaining):
                VStack(spacing: 12) {
                    Text("Saved to Jobs")
                        .font(.headline)

                    Button("Transcribe (\(ctaSecondsRemaining)s)") {
                        Task { @MainActor in
                            if let session = viewModel.consumeSessionForTranscribeCTA() {
                                appState.jobsViewModel.transcribe(session: session, context: modelContext)
                                appState.selectTab(.jobs)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .task {
            await viewModel.refresh()
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var microphonePicker: some View {
        Menu {
            ForEach(viewModel.availableDevices) { device in
                Button {
                    viewModel.selectedDevice = device
                } label: {
                    if viewModel.selectedDevice?.uid == device.uid {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            Label(viewModel.selectedDevice?.name ?? "Microphone", systemImage: "mic")
        }
    }

    private var appPicker: some View {
        Menu {
            Button {
                viewModel.selectedApp = nil
            } label: {
                if viewModel.selectedApp == nil {
                    Label("No App", systemImage: "checkmark")
                } else {
                    Text("No App")
                }
            }

            ForEach(viewModel.runningApps) { app in
                Button {
                    viewModel.selectedApp = app
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.selectedApp?.bundleID == app.bundleID {
                            Image(systemName: "checkmark")
                        }
                        appMenuRow(for: app)
                    }
                }
            }
        } label: {
            Label(viewModel.selectedApp?.name ?? "App", systemImage: "app")
        }
        .disabled(!viewModel.appAudioToggleEnabled)
        .simultaneousGesture(
            TapGesture().onEnded {
                viewModel.refreshApps()
            }
        )
    }

    private var appPickerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            appPicker

            if !viewModel.appAudioToggleEnabled {
                HStack(spacing: 6) {
                    Text("Screen Recording required")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open Settings") {
                        openScreenRecordingSettings()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func appMenuRow(for app: CapturedApp) -> some View {
        if let icon = app.icon {
            Label {
                Text(app.name)
            } icon: {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            }
        } else {
            Label(app.name, systemImage: "app")
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
