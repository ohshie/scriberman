import Foundation
import SwiftData

@MainActor
struct MainServiceContainer {
    let bookmarkStore: BookmarkStore
    let aiProviderService: AIProviderService
    let audioDeviceService: AudioDeviceService
    let appAudioService: AppAudioService
    let permissionService: PermissionServiceProtocol
    let transcriptExportService: TranscriptExportService
    let appAudioSettings: AppAudioSettings
}

struct BackgroundServiceContainer: Sendable {
    let workspaceService: WorkspaceService
    let modelInstallService: ModelInstallService
    let recordingService: RecordingService
    let transcriptionService: TranscriptionService
    let retranscriptionService: RetranscriptionService
    let audioImportService: AudioImportService
    let speakerEmbeddingStore: SpeakerEmbeddingStore
}

struct ServiceContainer {
    let main: MainServiceContainer
    let background: BackgroundServiceContainer

    @MainActor
    static func live(modelContainer: ModelContainer = defaultModelContainer()) -> ServiceContainer {
        let bookmarkStore = UserDefaultsBookmarkStore()
        let aiProviderStore = AIProviderStore()
        let speakerEmbeddingStore = SpeakerEmbeddingStore(modelContainer: modelContainer)
        let workspaceService = WorkspaceService(bookmarkStore: bookmarkStore)
        let transcriptionService = TranscriptionService(speakerEmbeddingStore: speakerEmbeddingStore)
        let retranscriptionService = RetranscriptionService(transcriptionService: transcriptionService)
        let audioImportService = AudioImportService(retranscriptionService: retranscriptionService)
        let appAudioSettings = AppAudioSettings()

        return ServiceContainer(
            main: MainServiceContainer(
                bookmarkStore: bookmarkStore,
                aiProviderService: AIProviderService(
                    keychainStore: LiveKeychainStore(),
                    store: aiProviderStore
                ),
                audioDeviceService: AudioDeviceService(),
                appAudioService: AppAudioService(),
                permissionService: PermissionService(),
                transcriptExportService: TranscriptExportService(),
                appAudioSettings: appAudioSettings
            ),
            background: BackgroundServiceContainer(
                workspaceService: workspaceService,
                modelInstallService: ModelInstallService(workspaceService: workspaceService),
                recordingService: RecordingService(
                    workspaceService: workspaceService,
                    modelContainer: modelContainer,
                    appAudioSettings: appAudioSettings
                ),
                transcriptionService: transcriptionService,
                retranscriptionService: retranscriptionService,
                audioImportService: audioImportService,
                speakerEmbeddingStore: speakerEmbeddingStore
            )
        )
    }

    private static func defaultModelContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: RecordingSession.self, ImportedSession.self, SpeakerProfile.self)
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error.localizedDescription)")
        }
    }
}
