import AppKit
import OSLog
import SwiftUI
import FluidAudio
import SwiftData

@main
struct ScribermanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private static let appModelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self, SpeakerProfile.self, RecordingTag.self)
        } catch {
            fatalError("Failed to initialize app model container: \(error.localizedDescription)")
        }
    }()

    @State private var appState = AppState(
        services: ServiceContainer.live(modelContainer: ScribermanApp.appModelContainer)
    )
    private let modelContainer = ScribermanApp.appModelContainer

    /// Seeds the default tag and brings recordings that predate tags up to it.
    ///
    /// Runs ahead of `bootstrapWorkspace`, and therefore ahead of anything that could start a
    /// recording, because recording creation applies the default tag. Deliberately not tied to
    /// Settings being opened.
    ///
    /// The backfill is eager rather than repaired on read: repairing lazily would leave the
    /// one-to-three bound false for every recording nobody had displayed yet.
    private static func prepareTags(in context: ModelContext) {
        let logger = Logger(subsystem: "Scriberman", category: "ScribermanApp")
        do {
            let service = TagService()
            try service.seedDefaultTagIfNeeded(in: context)
            let backfilled = try service.backfillUntaggedRecordings(in: context)
            if backfilled > 0 {
                logger.notice("Tag backfill brought \(backfilled, privacy: .public) recording(s) to the default tag.")
            }
        } catch {
            // Not fatal. `TagService.applyDefaultTag` seeds on demand, so a failure here costs the
            // backfill of existing recordings, not the invariant for new ones.
            logger.error("Preparing tags failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Gives existing sessions the text app-wide search narrows on.
    ///
    /// Separate from `prepareTags` because it fails differently: a failure here costs search over
    /// old sessions until the next launch, and nothing else.
    private static func prepareSearchText(in context: ModelContext) {
        let logger = Logger(subsystem: "Scriberman", category: "ScribermanApp")
        do {
            _ = try SessionSearchTextBackfill().backfill(in: context)
        } catch {
            logger.error("Backfilling search text failed: \(error.localizedDescription, privacy: .public)")
        }
    }

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
                    ScribermanApp.prepareTags(in: modelContainer.mainContext)
                    ScribermanApp.prepareSearchText(in: modelContainer.mainContext)
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
        // Settings is its own scene and does not inherit the WindowGroup's container. Without this
        // every `@Query` and `@Environment(\.modelContext)` inside Settings resolves to a throwaway
        // context: reads return nothing and writes go nowhere.
        .modelContainer(modelContainer)
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
