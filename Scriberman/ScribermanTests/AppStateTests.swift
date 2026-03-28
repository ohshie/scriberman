import SwiftData
import XCTest
@testable import Scriberman

@MainActor
final class AppStateTests: XCTestCase {
    private var modelContainer: ModelContainer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        modelContainer = try ModelContainer(
            for: RecordingSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    override func tearDown() {
        modelContainer = nil
        super.tearDown()
    }

    func testBootstrapWorkspaceShowsPermissionsOnboardingWhenUndetermined() async {
        let permissionService = MockPermissionService()
        permissionService.needsOnboardingValue = true
        let services = makeServiceContainer(permissionService: permissionService)
        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true))

        let appState = AppState(
            services: services,
            restoreWorkspaceHandler: { workspace }
        )

        await appState.bootstrapWorkspace()

        XCTAssertFalse(appState.workspaceSelectionRequired)
        XCTAssertEqual(appState.workspace, workspace)
        XCTAssertTrue(appState.showPermissionsOnboarding)
        XCTAssertEqual(permissionService.checkAllCalls, 1)
    }

    private func makeServiceContainer(permissionService: PermissionServiceProtocol) -> ServiceContainer {
        let bookmarkStore = TestBookmarkStore()
        let workspaceService = WorkspaceService(bookmarkStore: bookmarkStore)

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
            permissionService: permissionService,
            transcriptionService: TranscriptionService(),
            transcriptExportService: TranscriptExportService()
        )
    }
}

private final class TestBookmarkStore: BookmarkStore {
    private var bookmarkData: Data?

    func loadWorkspaceBookmark() -> Data? {
        bookmarkData
    }

    func saveWorkspaceBookmark(_ data: Data) {
        bookmarkData = data
    }
}
