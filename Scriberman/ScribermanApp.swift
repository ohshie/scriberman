import AppKit
import SwiftUI
import FluidAudio
import SwiftData
import OSLog

@main
struct ScribermanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private static let logger = Logger(subsystem: "Scriberman", category: "MenuBarFlow")

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
                set: {
                    ScribermanApp.logger.info("MenuBarExtra isInserted binding set to \($0)")
                    appState.menuBarSettings.isInTrayMode = $0
                }
            )
        ) {
            MenuBarExtraView(appState: appState)
                .onChange(of: appState.menuBarSettings.isInTrayMode) { _, isInserted in
                    ScribermanApp.logger.info("MenuBarExtra onChange isInTrayMode=\(isInserted)")
                    if isInserted {
                        (NSApp.delegate as? AppDelegate)?.finalizeHideToTrayIfRequested()
                        return
                    }

                    let changed = NSApp.setActivationPolicy(.regular)
                    ScribermanApp.logger.info("MenuBarExtra removal restore regular changed=\(changed)")
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
