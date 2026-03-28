import AppKit
import SwiftData
import SwiftUI

struct StudioView: View {
    @ObservedObject var viewModel: StudioViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Namespace private var glassNamespace

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 24) {
                if let errorMessage = viewModel.errorMessage {
                    errorBanner(errorMessage)
                }

                waveform

                statusBlock

                primaryControl

                secondaryControls
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await viewModel.refresh()
        }
    }

    private var waveform: some View {
        let level: Float
        switch viewModel.recordingState {
        case .idle, .stopped:
            level = 0
        case .recording(_, let liveLevel):
            level = liveLevel
        }

        return WaveformView(level: .constant(level))
            .frame(maxWidth: 560)
            .frame(height: 150)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusBlock: some View {
        switch viewModel.recordingState {
        case .idle:
            VStack(spacing: 6) {
                Text("Ready to record")
                    .font(.title2.weight(.semibold))

                if let selectedDeviceName = viewModel.selectedDevice?.name {
                    Text("Microphone: \(selectedDeviceName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let selectedAppName = viewModel.selectedApp?.name, viewModel.recordAppAudio {
                    Text("App audio: \(selectedAppName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)

        case .recording(let duration, _):
            VStack(spacing: 6) {
                Text("Recording")
                    .font(.title2.weight(.semibold))

                Text(durationText(duration))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

        case .stopped(_, let ctaSecondsRemaining):
            VStack(spacing: 6) {
                Text("Saved to Jobs")
                    .font(.title2.weight(.semibold))

                Text("Transcribe automatically in \(ctaSecondsRemaining)s")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var primaryControl: some View {
        GlassEffectContainer {
            switch viewModel.recordingState {
            case .idle:
                Button {
                    Task { await viewModel.startRecording() }
                } label: {
                    Label("New Recording", systemImage: "record.circle")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(!viewModel.canRecord)
                .glassEffectID("studio-primary-control", in: glassNamespace)

            case .recording:
                Button {
                    Task { await viewModel.stopRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.large)
                .glassEffectID("studio-primary-control", in: glassNamespace)

            case .stopped:
                Button {
                    Task { @MainActor in
                        guard let session = viewModel.consumeSessionForTranscribeCTA() else {
                            return
                        }

                        appState.jobsViewModel.transcribe(session: session, context: modelContext)
                        appState.selectDestination(.jobs)
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text("Transcribe Now")
                        Text("Uses the current recording")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 220)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .glassEffectID("studio-primary-control", in: glassNamespace)
            }
        }
    }

    private var secondaryControls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                microphonePicker
                appAudioToggle
            }

            if viewModel.showAppPicker {
                appPicker
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: 560)
    }

    @ViewBuilder
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
        .buttonStyle(.glass)
    }

    @ViewBuilder
    private var appAudioToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $viewModel.recordAppAudio) {
                Label("Record app audio", systemImage: "waveform")
            }
            .toggleStyle(.switch)
            .disabled(!viewModel.appAudioToggleEnabled)

            if !viewModel.appAudioToggleEnabled {
                Text("Screen Recording permission is required")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var appPicker: some View {
        Menu {
            if viewModel.selectedApp == nil {
                Button("Choose an app…") { }
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
            Label(viewModel.selectedApp?.name ?? "Choose an app…", systemImage: "app")
        }
        .buttonStyle(.glass)
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

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @ViewBuilder
    private func errorBanner(_ errorMessage: String) -> some View {
        Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
