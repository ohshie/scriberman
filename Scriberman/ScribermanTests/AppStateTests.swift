import SwiftData
import XCTest
@testable import Scriberman

@MainActor
final class AppStateTests: XCTestCase {
    private var modelContainer: ModelContainer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        modelContainer = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self,
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

    func testAppSourceDeclaresSettingsScene() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appFileURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("ScribermanApp.swift")
        let appSource = try String(contentsOf: appFileURL, encoding: .utf8)

        XCTAssertTrue(
            appSource.contains("Settings {"),
            "Expected ScribermanApp.swift to declare a SwiftUI Settings scene."
        )
    }

    func testSelectPendingSessionCreatesSinglePendingSession() {
        let permissionService = MockPermissionService()
        let services = makeServiceContainer(permissionService: permissionService)
        let appState = AppState(services: services)

        appState.selectPendingSession()
        let firstPending = appState.pendingSession
        appState.selectPendingSession()

        XCTAssertNotNil(firstPending)
        XCTAssertEqual(appState.pendingSession?.id, firstPending?.id)
    }

    func testDiscardPendingSessionClearsPendingAndResetsNewSessionState() {
        let permissionService = MockPermissionService()
        let services = makeServiceContainer(permissionService: permissionService)
        let appState = AppState(services: services)
        let recording = RecordingSession(
            createdAt: .now,
            duration: 5,
            micAudioURL: "/tmp/recording.wav",
            title: "Recorded",
            status: .recorded
        )

        appState.selectPendingSession()
        appState.newSessionViewModel.state = .stopped(session: recording)
        appState.discardPendingSession()

        XCTAssertNil(appState.pendingSession)
        guard case .idle = appState.newSessionViewModel.state else {
            return XCTFail("Expected new session state to reset to idle")
        }
    }

    private func makeServiceContainer(permissionService: PermissionServiceProtocol) -> ServiceContainer {
        let bookmarkStore = TestBookmarkStore()
        let workspaceService = WorkspaceService(bookmarkStore: bookmarkStore)
        let transcriptionService = TranscriptionService()
        let retranscriptionService = RetranscriptionService(transcriptionService: transcriptionService)
        let keychainStore = InMemoryKeychainStore()
        let defaultsSuite = "AppStateTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
        userDefaults.removePersistentDomain(forName: defaultsSuite)
        let aiProviderStore = AIProviderStore(defaults: userDefaults)

        return ServiceContainer(
            bookmarkStore: bookmarkStore,
            aiProviderService: AIProviderService(
                keychainStore: keychainStore,
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
            permissionService: permissionService,
            transcriptionService: transcriptionService,
            retranscriptionService: retranscriptionService,
            audioImportService: AudioImportService(retranscriptionService: retranscriptionService),
            transcriptExportService: TranscriptExportService()
        )
    }
}

private final class InMemoryKeychainStore: KeychainStore {
    private var storage: [String: String] = [:]

    func save(key: String, value: String) throws {
        storage[key] = value
    }

    func read(key: String) -> String? {
        storage[key]
    }

    func delete(key: String) throws {
        storage.removeValue(forKey: key)
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
