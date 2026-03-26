import Foundation
import SwiftData

struct ServiceContainer {
    let bookmarkStore: BookmarkStore
    let workspaceService: WorkspaceService
    let modelInstallService: ModelInstallService
    let recordingService: RecordingService

    static func live(modelContainer: ModelContainer = defaultModelContainer()) -> ServiceContainer {
        let bookmarkStore = UserDefaultsBookmarkStore()
        let workspaceService = WorkspaceService(bookmarkStore: bookmarkStore)

        return ServiceContainer(
            bookmarkStore: bookmarkStore,
            workspaceService: workspaceService,
            modelInstallService: ModelInstallService(workspaceService: workspaceService),
            recordingService: RecordingService(
                workspaceService: workspaceService,
                modelContainer: modelContainer
            )
        )
    }

    private static func defaultModelContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: RecordingSession.self)
        } catch {
            fatalError("Failed to initialize SwiftData container: \(error.localizedDescription)")
        }
    }
}
