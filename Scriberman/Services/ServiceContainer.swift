import Foundation
import SwiftData

struct ServiceContainer {
    let bookmarkStore: BookmarkStore
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

    @MainActor
    static func live(modelContainer: ModelContainer = defaultModelContainer()) -> ServiceContainer {
        let bookmarkStore = UserDefaultsBookmarkStore()
        let workspaceService = WorkspaceService(bookmarkStore: bookmarkStore)
        let transcriptionService = TranscriptionService()
        let retranscriptionService = RetranscriptionService(transcriptionService: transcriptionService)
        let audioImportService = AudioImportService(retranscriptionService: retranscriptionService)

        return ServiceContainer(
            bookmarkStore: bookmarkStore,
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
            transcriptExportService: TranscriptExportService()
        )
    }

    private static func defaultModelContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: RecordingSession.self, ImportedSession.self)
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error.localizedDescription)")
        }
    }
}
