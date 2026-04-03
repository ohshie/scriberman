import AppKit
import SwiftData
import SwiftUI

struct MenuBarExtraView: View {
    var appState: AppState

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        switch appState.newSessionViewModel.state {
        case .idle:
            idleMenu
        case let .recording(duration, _):
            recordingMenu(duration: duration)
        }
    }

    @ViewBuilder
    private var idleMenu: some View {
        Button("Start Recording") {
            startQuickRecording()
        }

        Menu("Record with…") {
            Text("Microphone and app selection will be added next.")
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
        Task {
            await appState.newSessionViewModel.startRecording(title: "Quick Recording", context: modelContext)
        }
    }

    private func menuDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
