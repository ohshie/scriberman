import AppKit
import SwiftData
import SwiftUI

struct MenuBarExtraView: View {
    var appState: AppState

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            switch appState.newSessionViewModel.state {
            case .idle:
                idleMenu
            case let .recording(duration, _):
                recordingMenu(duration: duration)
            }
        }
        .onAppear {
            appState.audioDeviceService.refreshDevices()
            appState.appAudioService.refreshRunningApps()
        }
    }

    @ViewBuilder
    private var idleMenu: some View {
        Button("Start Recording") {
            startQuickRecording()
        }

        Menu("Record with…") {
            Text("Microphone")

            ForEach(appState.audioDeviceService.availableDevices) { device in
                Button {
                    appState.menuBarSettings.lastUsedMicUID = device.uid
                    startQuickRecording()
                } label: {
                    if appState.menuBarSettings.lastUsedMicUID == device.uid {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }

            Divider()

            Text("App Audio")

            Button {
                appState.menuBarSettings.lastUsedAppBundleID = nil
                startQuickRecording()
            } label: {
                if appState.menuBarSettings.lastUsedAppBundleID == nil {
                    Label("No App Audio", systemImage: "checkmark")
                } else {
                    Text("No App Audio")
                }
            }

            ForEach(appState.appAudioService.runningApps) { app in
                Button {
                    appState.menuBarSettings.lastUsedAppBundleID = app.bundleID
                    startQuickRecording()
                } label: {
                    if appState.menuBarSettings.lastUsedAppBundleID == app.bundleID {
                        Label(app.name, systemImage: "checkmark")
                    } else {
                        Text(app.name)
                    }
                }
            }
        }

        Divider()

        Button("Open Scriberman") {
            (NSApp.delegate as? AppDelegate)?.showMainWindow()
        }

        Divider()

        Button("Quit Scriberman") {
            NSApp.terminate(nil)
        }
    }

    @ViewBuilder
    private func recordingMenu(duration: TimeInterval) -> some View {
        Text("Recording: \(menuDuration(duration))")
            .disabled(true)

        Button("Stop Recording") {
            Task {
                _ = await appState.newSessionViewModel.stopRecording(context: modelContext)
            }
        }

        Divider()

        Button("Open Scriberman") {
            (NSApp.delegate as? AppDelegate)?.showMainWindow()
        }

        Divider()

        Button("Quit Scriberman") {
            NSApp.terminate(nil)
        }
    }

    private func startQuickRecording() {
        let selectedMic = appState.menuBarSettings.lastUsedMicUID
        let selectedApp = appState.appAudioService.runningApps.first {
            $0.bundleID == appState.menuBarSettings.lastUsedAppBundleID
        }

        Task {
            await appState.newSessionViewModel.startRecording(
                title: "Quick Recording",
                micDeviceUID: selectedMic,
                app: selectedApp,
                context: modelContext
            )
        }
    }

    private func menuDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
