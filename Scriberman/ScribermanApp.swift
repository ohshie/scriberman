import AppKit
import SwiftUI
import FluidAudio
import SwiftData

@main
struct ScribermanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private static let appModelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: RecordingSession.self, ImportedSession.self, SpeakerProfile.self)
        } catch {
            fatalError("Failed to initialize app model container: \(error.localizedDescription)")
        }
    }()

    @State private var appState = AppState(
        services: ServiceContainer.live(modelContainer: ScribermanApp.appModelContainer)
    )
    private let modelContainer = ScribermanApp.appModelContainer

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(appState.aiProviderService)
                .task {
                    appDelegate.appState = appState
                    await appState.bootstrapWorkspace()
                }
        }
        .modelContainer(modelContainer)
        .commands {
            SidebarCommands()
        }

        Settings {
            SettingsView(viewModel: appState.settingsViewModel)
                .environment(appState)
                .environment(appState.aiProviderService)
        }

        MenuBarExtra(
            isInserted: Binding(
                get: { appState.menuBarSettings.isInTrayMode },
                set: { appState.menuBarSettings.isInTrayMode = $0 }
            )
        ) {
            MenuBarExtraView(appState: appState)
                .onChange(of: appState.menuBarSettings.isInTrayMode) { _, isInserted in
                    guard isInserted == false else {
                        return
                    }

                    _ = NSApp.setActivationPolicy(.regular)
                    appState.menuBarSettings.isInTrayMode = false
                }
        } label: {
            switch appState.newSessionViewModel.state {
            case .idle:
                Image(systemName: "circle.fill")
                    .foregroundStyle(.red)
            case let .recording(duration, _):
                Text(Self.menuBarDuration(duration))
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.menu)
    }

    private static func menuBarDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
