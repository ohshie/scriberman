import SwiftUI
import FluidAudio
import SwiftData

@main
struct ScribermanApp: App {
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
    }
}
