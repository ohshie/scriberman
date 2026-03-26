import Foundation

struct ServiceContainer {
    let bookmarkStore: BookmarkStore
    let workspaceService: WorkspaceService
    let modelInstallService: ModelInstallService

    static func live() -> ServiceContainer {
        let bookmarkStore = UserDefaultsBookmarkStore()
        return ServiceContainer(
            bookmarkStore: bookmarkStore,
            workspaceService: WorkspaceService(bookmarkStore: bookmarkStore),
            modelInstallService: ModelInstallService()
        )
    }
}
