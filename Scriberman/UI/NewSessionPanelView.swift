import AppKit
import SwiftData
import SwiftUI

struct NewSessionPanelView: View {
    var viewModel: NewSessionViewModel
    @Binding var pendingSession: PendingSession
    var onRecordingFinished: (RecordingSession) -> Void
    var onImportFile: () -> Void = {}

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let permissionStatusWarningText = viewModel.permissionStatusWarningText {
                VStack(alignment: .leading, spacing: 10) {
                    Label(permissionStatusWarningText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.yellow)

                    HStack(spacing: 8) {
                        Button("Re-check Permissions") {
                            Task {
                                await viewModel.recheckPermissions()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if !viewModel.microphonePermissionGranted {
                            Button("Grant Mic Access") {
                                Task {
                                    await viewModel.requestMicrophonePermission()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        if !viewModel.screenRecordingPermissionGranted {
                            Button("Request Screen Access") {
                                viewModel.requestScreenRecordingPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button("Open Privacy Settings") {
                            openPrivacySettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.yellow.opacity(0.16))
                )
            }

            if let errorMessage = viewModel.errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.yellow.opacity(0.16))
                )
            }

            switch viewModel.state {
            case .idle:
                idleState
            case let .recording(duration, level):
                recordingState(duration: duration, level: level)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear {
            viewModel.refreshAudioDevicesOnAppear()
        }
    }

    private var idleState: some View {
        VStack(alignment: .leading, spacing: 16) {
            sessionNameEditorCard

            FlowingWaveView(level: 0, showAppWave: false, isRecording: false)
                .frame(height: 110)

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

            HStack {
                Spacer()
                Button {
                    Task {
                        await viewModel.startRecording(title: pendingSession.title, context: modelContext)
                    }
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .buttonStyle(.glassProminent)
                .disabled(!viewModel.canRecord)
                Spacer()
            }

            Button("or Import File") {
                onImportFile()
            }
            .buttonStyle(.borderless)
        }
    }

    private func recordingState(duration: TimeInterval, level: Float) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sessionNameReadOnlyCard

            FlowingWaveView(level: level, showAppWave: viewModel.recordAppAudio, isRecording: true)
                .frame(height: 110)

            Text(durationText(duration))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)

            if !viewModel.liveSegments.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(viewModel.liveSegments.enumerated()), id: \.offset) { _, segment in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(segment.audioSource == .mic ? "Mic" : "App")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Capsule().stroke(.secondary.opacity(0.3)))

                                    Text(segment.text)
                                        .font(.callout)
                                        .foregroundStyle(segment.isFinal ? .primary : .secondary)
                                }
                                .id(segment.startTime)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .frame(height: 120)
                    .onChange(of: viewModel.liveSegments.count) {
                        if let last = viewModel.liveSegments.last {
                            proxy.scrollTo(last.startTime, anchor: .bottom)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    Task {
                        if let session = await viewModel.stopRecording(context: modelContext) {
                            onRecordingFinished(session)
                        }
                    }
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                Spacer()
            }

            controlsSection(isInteractive: false)
        }
    }

    private func controlsSection(isInteractive: Bool) -> some View {
        @Bindable var bindableViewModel = viewModel

        return VStack(spacing: 0) {
            microphoneMenu
                .disabled(!isInteractive)

            Divider()

            HStack(spacing: 12) {
                Label("Record app audio", systemImage: "waveform")
                Spacer(minLength: 0)
                Toggle("", isOn: $bindableViewModel.recordAppAudio)
                    .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .disabled(!isInteractive || !viewModel.appAudioToggleEnabled)

            if viewModel.showAppPicker {
                Divider()
                appPicker
                    .disabled(!isInteractive)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .disabled(!isInteractive)
        .opacity(isInteractive ? 1 : 0.65)
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
            HStack(spacing: 12) {
                Label(viewModel.selectedDevice?.name ?? "Microphone", systemImage: "mic")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            HStack(spacing: 12) {
                Label(viewModel.selectedApp?.name ?? "Choose app", systemImage: "app")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .padding(.leading, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sessionNameEditorCard: some View {
        TextField("Untitled Session", text: $pendingSession.title)
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
    }

    private var sessionNameReadOnlyCard: some View {
        Text(pendingSession.title.isEmpty ? "Untitled Session" : pendingSession.title)
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func openPrivacySettings() {
        if let micURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(micURL)
        }
        if let screenURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(screenURL)
        }
    }
}
