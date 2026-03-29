import Foundation
import SwiftData

struct ServiceContainer {
    let bookmarkStore: BookmarkStore
    let aiProviderService: AIProviderService
    let workspaceService: WorkspaceService
    let modelInstallService: ModelInstallService
    let recordingService: RecordingService
    let audioDeviceService: AudioDeviceService
    let appAudioService: AppAudioService
    let permissionService: PermissionServiceProtocol
    let transcriptionService: TranscriptionService
    let retranscriptionService: RetranscriptionService
    let audioImportService: AudioImportService
    let transcriptExportService: TranscriptExportService
    let speakerEmbeddingStore: SpeakerEmbeddingStore

    @MainActor
    static func live(modelContainer: ModelContainer = defaultModelContainer()) -> ServiceContainer {
        let bookmarkStore = UserDefaultsBookmarkStore()
        let aiProviderStore = AIProviderStore()
        let speakerEmbeddingStore = SpeakerEmbeddingStore(modelContainer: modelContainer)
        let workspaceService = WorkspaceService(bookmarkStore: bookmarkStore)
        let transcriptionService = TranscriptionService(speakerEmbeddingStore: speakerEmbeddingStore)
        let retranscriptionService = RetranscriptionService(transcriptionService: transcriptionService)
        let audioImportService = AudioImportService(retranscriptionService: retranscriptionService)

        return ServiceContainer(
            bookmarkStore: bookmarkStore,
            aiProviderService: AIProviderService(
                keychainStore: LiveKeychainStore(),
                store: aiProviderStore
            ),
            workspaceService: workspaceService,
            modelInstallService: ModelInstallService(workspaceService: workspaceService),
            recordingService: RecordingService(
                workspaceService: workspaceService,
                modelContainer: modelContainer
            ),
            audioDeviceService: AudioDeviceService(),
            appAudioService: AppAudioService(),
            permissionService: PermissionService(),
            transcriptionService: transcriptionService,
            retranscriptionService: retranscriptionService,
            audioImportService: audioImportService,
            transcriptExportService: TranscriptExportService(),
            speakerEmbeddingStore: speakerEmbeddingStore
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
