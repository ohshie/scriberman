import AppKit
import SwiftData
import SwiftUI

struct NewSessionPanelView: View {
    var viewModel: NewSessionViewModel
    @Binding var pendingSession: PendingSession
    var onRecordingStarted: (RecordingSession) -> Void = { _ in }
    var onImportFile: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @State private var isNameCardHovering = false

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

            idleState
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(20)
        .onAppear {
            viewModel.refreshAudioDevicesOnAppear()
        }
    }

    private var idleState: some View {
        VStack(spacing: 20) {
            sessionNameEditor

            recordHeroButton

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

            Button("Import File…") {
                onImportFile()
            }
            .buttonStyle(.borderless)
        }
    }

    private var recordHeroButton: some View {
        VStack(spacing: 8) {
            Button {
                Task {
                    if let session = await viewModel.startRecording(title: pendingSession.title, context: modelContext) {
                        onRecordingStarted(session)
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.tint.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 62, height: 62)
                    Circle()
                        .fill(.tint)
                        .frame(width: 46, height: 46)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canRecord)
            .opacity(viewModel.canRecord ? 1 : 0.4)
            .accessibilityLabel("Record")

            Text("Record")
                .font(.callout.weight(.medium))
                .foregroundStyle(viewModel.canRecord ? .primary : .secondary)
        }
    }

    private func controlsSection(isInteractive: Bool) -> some View {
        return VStack(spacing: 0) {
            microphoneMenu
                .disabled(!isInteractive)

            Divider()

            appAudioToggleRow
                .disabled(!isInteractive)

            if viewModel.showAppPicker {
                Divider()

                appAudioMenu
                    .disabled(!isInteractive)
            }

            Divider()

            screenRecordingToggleRow
                .disabled(!isInteractive)

            if viewModel.showDisplayPicker {
                Divider()

                displayMenu
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
        .simultaneousGesture(TapGesture().onEnded {
            viewModel.refreshAudioDevicesOnPanelExpanded()
        })
    }

    private var appAudioMenu: some View {
        Menu {
            Button("Off") {
                viewModel.selectApp(nil)
            }

            Divider()

            ForEach(viewModel.runningApps) { app in
                Button {
                    viewModel.selectApp(app)
                } label: {
                    if let appIcon = app.icon {
                        Label {
                            Text(app.name)
                        } icon: {
                            Image(nsImage: appIcon)
                        }
                    } else {
                        Label {
                            Text(app.name)
                        } icon: {
                            Image(systemName: "app")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                if let selectedApp = viewModel.selectedApp {
                    HStack(spacing: 8) {
                        if let icon = selectedApp.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 16, height: 16)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        } else {
                            Image(systemName: "app")
                                .frame(width: 16, height: 16)
                        }

                        Text(selectedApp.name)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label("Select app to record", systemImage: "waveform")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            viewModel.refreshApps()
        })
    }

    private var appAudioToggleRow: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { viewModel.recordAppAudio },
                set: { viewModel.recordAppAudio = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record app audio")
                    if viewModel.recordAppAudio {
                        Text(viewModel.selectedApp?.name ?? "Choose an app below")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var screenRecordingToggleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { viewModel.recordScreen },
                set: { viewModel.recordScreen = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record screen")
                    if viewModel.recordScreen, let selectedDisplay = viewModel.selectedDisplay {
                        Text("\(selectedDisplay.name) • \(selectedDisplay.resolutionLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if !viewModel.screenRecordingPermissionGranted {
                        Text("Screen Recording permission required")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .disabled(!viewModel.screenRecordingPermissionGranted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var displayMenu: some View {
        Menu {
            ForEach(viewModel.availableDisplays) { display in
                Button {
                    viewModel.selectedDisplayID = display.displayID
                } label: {
                    if viewModel.selectedDisplayID == display.displayID {
                        Label("\(display.name) • \(display.resolutionLabel)", systemImage: "checkmark")
                    } else {
                        Text("\(display.name) • \(display.resolutionLabel)")
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Label(
                    viewModel.selectedDisplay.map { "\($0.name) • \($0.resolutionLabel)" } ?? "Select display",
                    systemImage: "display"
                )
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
        .simultaneousGesture(TapGesture().onEnded {
            Task {
                await viewModel.recheckPermissions()
            }
        })
    }

    private var sessionNameEditor: some View {
        TextField("Untitled Session", text: $pendingSession.title)
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .overlay(alignment: .trailing) {
                if isNameCardHovering {
                    Label("Edit", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { hovering in
                isNameCardHovering = hovering
            }
            .animation(.easeInOut(duration: 0.15), value: isNameCardHovering)
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
