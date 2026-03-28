import SwiftUI
import FluidAudio
import SwiftData

@main
struct ScribermanApp: App {
    @StateObject private var appState: AppState
    private let modelContainer: ModelContainer

    init() {
        do {
            let modelContainer = try ModelContainer(for: RecordingSession.self, ImportedSession.self)
            self.modelContainer = modelContainer
            _appState = StateObject(
                wrappedValue: AppState(
                    services: ServiceContainer.live(modelContainer: modelContainer)
                )
            )
        } catch {
            fatalError("Failed to initialize app model container: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    await appState.bootstrapWorkspace()
                }
        }
        .modelContainer(modelContainer)
        .commands {
            SidebarCommands()
        }
    }
}
