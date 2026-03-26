import SwiftUI
import FluidAudio
import SwiftData

@main
struct ScribermanApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    await appState.bootstrapWorkspace()
                }
        }
        .modelContainer(for: [RecordingSession.self])
    }
}
