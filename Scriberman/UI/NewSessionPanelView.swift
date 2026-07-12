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

            Button {
                onImportFile()
            } label: {
                Label("Import File…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
        }
    }

    private var recordHeroButton: some View {
        HeroCircleButton(
            innerShape: .circle,
            tint: .accentColor,
            caption: "Record",
            isEnabled: viewModel.canRecord
        ) {
            Task {
                if let session = await viewModel.startRecording(title: pendingSession.title, context: modelContext) {
                    onRecordingStarted(session)
                }
            }
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
        HStack(spacing: 0) {
            microphoneDeviceMenu

            if let warning = viewModel.micPermissionWarningText {
                permissionWarningButton(reason: warning) {
                    if viewModel.micPermissionDenied {
                        openPrivacySettings(pane: "Privacy_Microphone")
                    } else {
                        Task {
                            await viewModel.requestMicrophonePermission()
                        }
                    }
                }
                .padding(.trailing, 12)
            }
        }
    }

    private var microphoneDeviceMenu: some View {
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
            .padding(.leading, 28)
            .padding(.trailing, 12)
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
            Text("Record app audio")

            Spacer()

            Toggle("Record app audio", isOn: Binding(
                get: { viewModel.recordAppAudio },
                set: { viewModel.recordAppAudio = $0 }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var screenRecordingToggleRow: some View {
        HStack(spacing: 12) {
            Text("Record screen")

            Spacer()

            if let warning = viewModel.screenPermissionWarningText {
                permissionWarningButton(reason: warning) {
                    if viewModel.screenPermissionDenied {
                        openPrivacySettings(pane: "Privacy_ScreenCapture")
                    } else {
                        viewModel.requestScreenRecordingPermission()
                    }
                }
            }

            Toggle("Record screen", isOn: Binding(
                get: { viewModel.recordScreen },
                set: { viewModel.recordScreen = $0 }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
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
            .padding(.leading, 28)
            .padding(.trailing, 12)
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
            .editableTitleHover(isHovering: $isNameCardHovering)
    }

    private func permissionWarningButton(reason: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
        .buttonStyle(.plain)
        .help(reason)
        .accessibilityLabel(reason)
    }

    private func openPrivacySettings(pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
