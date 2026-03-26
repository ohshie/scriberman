import Foundation

struct ServiceContainer {
    let bookmarkStore: BookmarkStore
    let workspaceService: WorkspaceService
    let modelInstallService: ModelInstallService

    static func live() -> ServiceContainer {
        let bookmarkStore = UserDefaultsBookmarkStore()
        let workspaceService = WorkspaceService(bookmarkStore: bookmarkStore)

        return ServiceContainer(
            bookmarkStore: bookmarkStore,
            workspaceService: workspaceService,
            modelInstallService: ModelInstallService(workspaceService: workspaceService)
        )
    }
}
