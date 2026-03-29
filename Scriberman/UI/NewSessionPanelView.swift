import SwiftData
import SwiftUI

struct NewSessionPanelView: View {
    @ObservedObject var viewModel: NewSessionViewModel
    @Binding var pendingSession: PendingSession
    var onTranscribe: (RecordingSession) -> Void
    var onImportFile: () -> Void = {}

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch viewModel.state {
            case .idle:
                idleState
            case let .recording(duration, level):
                recordingState(duration: duration, level: level)
            case let .stopped(session):
                stoppedState(session: session)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var idleState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session")
                .font(.title2.weight(.semibold))

            TextField("Session name", text: $pendingSession.title)
                .textFieldStyle(.roundedBorder)

            controlsSection(isInteractive: true)

            if viewModel.shouldShowMicrophonePermissionPrompt {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.microphonePermissionPromptText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Grant Microphone Access") {
                        Task {
                            await viewModel.requestMicrophonePermission()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Button {
                Task {
                    await viewModel.startRecording(title: pendingSession.title, context: modelContext)
                }
            } label: {
                Label("Record", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(!viewModel.canRecord)

            Button("or Import File") {
                onImportFile()
            }
            .buttonStyle(.borderless)
        }
    }

    private func recordingState(duration: TimeInterval, level: Float) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording")
                .font(.title2.weight(.semibold))

            WaveformView(level: .constant(level))
                .frame(height: 110)

            Text(durationText(duration))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                Task {
                    await viewModel.stopRecording(context: modelContext)
                }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)

            controlsSection(isInteractive: false)
        }
    }

    private func stoppedState(session: RecordingSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ready to Transcribe")
                .font(.title2.weight(.semibold))

            TextField(
                "Session name",
                text: Binding(
                    get: { session.title },
                    set: { session.title = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)

            Text(durationText(session.duration))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                onTranscribe(session)
            } label: {
                Label("Transcribe", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        }
    }

    private func controlsSection(isInteractive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            microphoneMenu
                .disabled(!isInteractive)

            Toggle(isOn: $viewModel.recordAppAudio) {
                Label("Record app audio", systemImage: "waveform")
            }
            .disabled(!isInteractive || !viewModel.appAudioToggleEnabled)

            if viewModel.showAppPicker {
                appPicker
                    .disabled(!isInteractive)
            }
        }
    }

    private var microphoneMenu: some View {
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
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var appPicker: some View {
        Menu {
            ForEach(viewModel.runningApps) { app in
                Button {
                    viewModel.selectedApp = app
                } label: {
                    if viewModel.selectedApp?.bundleID == app.bundleID {
                        Label(app.name, systemImage: "checkmark")
                    } else {
                        Text(app.name)
                    }
                }
            }
        } label: {
            Label(viewModel.selectedApp?.name ?? "Choose app", systemImage: "app")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
