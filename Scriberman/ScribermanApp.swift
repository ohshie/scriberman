import AppKit
import SwiftUI
import FluidAudio
import SwiftData

@main
struct ScribermanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private static let appModelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self, SpeakerProfile.self)
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
                    appDelegate.modelContext = modelContainer.mainContext
                    appDelegate.wireIdleSessionPrompt()
                    // macOS resets to the bundle icon on every launch, so re-apply the choice.
                    appState.appIconPreferences.apply()
                    await appState.bootstrapWorkspace()
                }
                .onChange(of: appState.dictationService.state) { _, _ in
                    appDelegate.refreshStatusItemIcon()
                }
        }
        .modelContainer(modelContainer)
        .commands {
            SidebarCommands()
            TrimCommands(appState: appState)
            ScribermanUpdateCommands(updateService: appState.updateService)
        }

        Settings {
            SettingsView(
                viewModel: appState.settingsViewModel,
                updateService: appState.updateService
            )
                .environment(appState)
                .environment(appState.aiProviderService)
        }
    }
}

private struct ScribermanUpdateCommands: Commands {
    let updateService: UpdateService

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updateService.checkForUpdates()
            }
            .disabled(!updateService.canCheckForUpdates)
        }
    }
}
