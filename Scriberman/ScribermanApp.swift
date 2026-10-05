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
            return try ModelContainer(for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self, SpeakerProfile.self, SpeakerVoiceprint.self, RecordingTag.self)
        } catch {
            fatalError("Failed to initialize app model container: \(error.localizedDescription)")
        }
    }()

    @State private var appState = AppState(
        services: ServiceContainer.live(modelContainer: ScribermanApp.appModelContainer)
    )
    private let modelContainer = ScribermanApp.appModelContainer

    init() {
        // FluidAudio's ASR debug lines include recognised words, and Debug builds mirror every
        // level to the console. `.info` drops those lines and keeps model-load and download logs.
        AppLogger.minimumLevel = .info
    }

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

    /// Removes live transcript segments left without a recording by versions that did not cascade
    /// the delete. Idempotent; a failure costs only the cleanup, retried at the next launch.
    static func removeOrphanedTranscriptSegments(in context: ModelContext) {
        let logger = Logger(subsystem: "Scriberman", category: "ScribermanApp")
        do {
            let removed = try RecordingTranscriptSegment.deleteOrphans(in: context)
            if removed > 0 {
                logger.notice("Removed \(removed, privacy: .public) orphaned transcript segment(s).")
            }
        } catch {
            logger.error("Removing orphaned transcript segments failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Empties speaker memory when its voiceprint space changed, before anything can transcribe.
    /// Profiles from another space cannot be compared with new voiceprints. A failure leaves the
    /// marker unset, so the reset is retried at the next launch; matching skips other spaces
    /// meanwhile.
    private static func resetSpeakerMemoryIfVoiceprintSpaceChanged(in context: ModelContext) {
        let logger = Logger(subsystem: "Scriberman", category: "ScribermanApp")
        do {
            let removed = try SpeakerProfile.resetIfVoiceprintSpaceChanged(in: context, userDefaults: .standard)
            if removed > 0 {
                logger.notice("Voiceprint space changed: removed \(removed, privacy: .public) speaker profile(s).")
            }
        } catch {
            logger.error("Resetting speaker memory failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Gives every profile stored before voiceprint lists existed one source-less voiceprint. A
    /// failure is retried at the next launch; the cached mean keeps matching correct meanwhile.
    private static func migrateSpeakerProfilesToVoiceprintLists(in context: ModelContext) {
        let logger = Logger(subsystem: "Scriberman", category: "ScribermanApp")
        do {
            let migrated = try SpeakerProfile.migrateToVoiceprintLists(in: context)
            if migrated > 0 {
                logger.notice("Migrated \(migrated, privacy: .public) speaker profile(s) to voiceprint lists.")
            }
        } catch {
            logger.error("Migrating speaker profiles to voiceprint lists failed: \(error.localizedDescription, privacy: .public)")
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
                    appDelegate.wireCalendarSuggestions()
                    // macOS resets to the bundle icon on every launch, so re-apply the choice.
                    appState.appIconPreferences.apply()
                    ScribermanApp.prepareTags(in: modelContainer.mainContext)
                    ScribermanApp.prepareSearchText(in: modelContainer.mainContext)
                    ScribermanApp.removeOrphanedTranscriptSegments(in: modelContainer.mainContext)
                    ScribermanApp.resetSpeakerMemoryIfVoiceprintSpaceChanged(in: modelContainer.mainContext)
                    ScribermanApp.migrateSpeakerProfilesToVoiceprintLists(in: modelContainer.mainContext)
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
