import Foundation
import SwiftData

@MainActor
struct MainServiceContainer {
    let bookmarkStore: BookmarkStore
    let aiProviderService: AIProviderService
    let audioDeviceService: AudioDeviceService
    let appAudioService: AppAudioService
    let screenCaptureService: ScreenCaptureServiceProtocol
    let permissionService: PermissionServiceProtocol
    let transcriptExportService: TranscriptExportService
    let appAudioSettings: AppAudioSettings
    let calendarService: CalendarServiceProtocol
    let calendarPreferences: CalendarSuggestionPreferences
}

struct BackgroundServiceContainer: Sendable {
    let workspaceService: WorkspaceService
    let modelInstallService: ModelInstallService
    let recordingService: RecordingService
    let transcriptionService: TranscriptionService
    let retranscriptionService: RetranscriptionService
    let audioImportService: AudioImportService
    let speakerEmbeddingStore: SpeakerEmbeddingStore
    let recoveryService: RecordingRecoveryService
    let recordingFinalizer: RecordingFinalizer
    let sessionJobs: SessionJobs
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
        let sessionJobs = SessionJobs()
        let retranscriptionService = RetranscriptionService(
            transcriptionService: transcriptionService,
            sessionJobs: sessionJobs
        )
        let audioImportService = AudioImportService(
            retranscriptionService: retranscriptionService,
            sessionJobs: sessionJobs
        )
        let recordingFinalizer = RecordingFinalizer(
            mixdownCoordinator: RecordingMixdownCoordinator(
                workspaceService: workspaceService,
                modelContainer: modelContainer,
                sessionJobs: sessionJobs
            ),
            screenVideoMuxer: ScreenVideoMuxer(
                workspaceService: workspaceService,
                modelContainer: modelContainer,
                sessionJobs: sessionJobs
            ),
            sessionJobs: sessionJobs
        )
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
                screenCaptureService: ScreenCaptureService(),
                permissionService: PermissionService(),
                transcriptExportService: TranscriptExportService(),
                appAudioSettings: appAudioSettings,
                calendarService: EventKitCalendarService(),
                calendarPreferences: CalendarSuggestionPreferences()
            ),
            background: BackgroundServiceContainer(
                workspaceService: workspaceService,
                modelInstallService: ModelInstallService(workspaceService: workspaceService),
                recordingService: RecordingService(
                    workspaceService: workspaceService,
                    modelContainer: modelContainer,
                    appAudioSettings: appAudioSettings,
                    finalizer: recordingFinalizer
                ),
                transcriptionService: transcriptionService,
                retranscriptionService: retranscriptionService,
                audioImportService: audioImportService,
                speakerEmbeddingStore: speakerEmbeddingStore,
                recoveryService: RecordingRecoveryService(
                    workspaceService: workspaceService,
                    modelContainer: modelContainer,
                    isFinalizing: { recordingFinalizer.isFinalizing(sessionID: $0) },
                    sessionJobs: sessionJobs
                ),
                recordingFinalizer: recordingFinalizer,
                sessionJobs: sessionJobs
            )
        )
    }

    private static func defaultModelContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self, SpeakerProfile.self, SpeakerVoiceprint.self, RecordingTag.self)
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error.localizedDescription)")
        }
    }
}
