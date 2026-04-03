import SwiftData
import XCTest
@testable import Scriberman

@MainActor
final class AppStateTests: XCTestCase {
    nonisolated(unsafe) private var modelContainer: ModelContainer!

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

    func testIsBootstrappingIsTrueInitially() {
        let appState = AppState(services: makeServiceContainer(permissionService: MockPermissionService()))
        XCTAssertTrue(appState.isBootstrapping)
    }

    func testIsBootstrappingIsFalseAfterBootstrapWorkspaceCompletes() async {
        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true))
        let appState = AppState(
            services: makeServiceContainer(permissionService: MockPermissionService()),
            restoreWorkspaceHandler: { workspace }
        )

        await appState.bootstrapWorkspace()

        XCTAssertFalse(appState.isBootstrapping)
    }

    func testRequiredOnboardingStepReturnsNilWhenEverythingIsReady() async {
        let permissionService = MockPermissionService()
        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        permissionService.verifyMicResult = true
        permissionService.verifyScreenRecordingResult = true
        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true))

        let appState = AppState(
            services: makeServiceContainer(permissionService: permissionService),
            restoreWorkspaceHandler: { workspace }
        )

        await appState.bootstrapWorkspace()
        appState.settingsViewModel.bundlePhase = .allReady

        XCTAssertNil(appState.requiredOnboardingStep)
    }

    func testRequiredOnboardingStepPrioritizesScreenRecording() {
        let permissionService = MockPermissionService()
        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .denied
        let appState = AppState(services: makeServiceContainer(permissionService: permissionService))
        appState.settingsViewModel.bundlePhase = .allReady

        XCTAssertEqual(appState.requiredOnboardingStep, .screenRecording)
    }

    func testRequiredOnboardingStepReturnsMicrophoneWhenScreenRecordingGranted() {
        let permissionService = MockPermissionService()
        permissionService.micStatus = .denied
        permissionService.screenRecordingStatus = .granted
        let appState = AppState(services: makeServiceContainer(permissionService: permissionService))
        appState.settingsViewModel.bundlePhase = .allReady

        XCTAssertEqual(appState.requiredOnboardingStep, .microphone)
    }

    func testRequiredOnboardingStepReturnsWorkspaceWhenPermissionsGranted() {
        let permissionService = MockPermissionService()
        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        let appState = AppState(services: makeServiceContainer(permissionService: permissionService))
        appState.settingsViewModel.bundlePhase = .allReady

        XCTAssertEqual(appState.requiredOnboardingStep, .workspace)
    }

    func testRequiredOnboardingStepReturnsModelsWhenWorkspacePresentAndBundleNotReady() async {
        let permissionService = MockPermissionService()
        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        permissionService.verifyMicResult = true
        permissionService.verifyScreenRecordingResult = true
        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true))

        let appState = AppState(
            services: makeServiceContainer(permissionService: permissionService),
            restoreWorkspaceHandler: { workspace }
        )

        await appState.bootstrapWorkspace()
        appState.settingsViewModel.bundlePhase = .idle

        XCTAssertEqual(appState.requiredOnboardingStep, .models)
    }

    func testBootstrapWorkspacePerformsStrictPermissionVerificationBeforeAppShell() async {
        let permissionService = MockPermissionService()
        permissionService.verifyMicResult = true
        permissionService.verifyScreenRecordingResult = true
        let services = makeServiceContainer(permissionService: permissionService)
        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true))

        let appState = AppState(
            services: services,
            restoreWorkspaceHandler: { workspace }
        )

        await appState.bootstrapWorkspace()

        XCTAssertEqual(permissionService.checkAllCalls, 1)
        XCTAssertEqual(permissionService.verifyMicCalls, 1)
        XCTAssertEqual(permissionService.verifyScreenRecordingCalls, 1)
        XCTAssertEqual(appState.workspace, workspace)
    }

    func testRefreshPermissionsOnActivationPerformsStrictVerification() async {
        let permissionService = MockPermissionService()
        let services = makeServiceContainer(permissionService: permissionService)
        let appState = AppState(services: services)

        await appState.refreshPermissionsOnActivation()

        XCTAssertEqual(permissionService.checkAllCalls, 1)
        XCTAssertEqual(permissionService.verifyMicCalls, 1)
        XCTAssertEqual(permissionService.verifyScreenRecordingCalls, 1)
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
        _ = RecordingSession(
            createdAt: .now,
            duration: 5,
            micAudioURL: "/tmp/recording.wav",
            title: "Recorded",
            status: .recorded
        )

        appState.selectPendingSession()
        appState.newSessionViewModel.state = .recording(duration: 10, level: 0)
        appState.discardPendingSession()

        XCTAssertNil(appState.pendingSession)
        guard case .idle = appState.newSessionViewModel.state else {
            return XCTFail("Expected new session state to reset to idle")
        }
    }

    private func makeServiceContainer(permissionService: PermissionServiceProtocol) -> ServiceContainer {
        let bookmarkStore = TestBookmarkStore()
        let workspaceService = WorkspaceService(bookmarkStore: bookmarkStore)
        let speakerEmbeddingStore = SpeakerEmbeddingStore(modelContainer: modelContainer)
        let transcriptionService = TranscriptionService(speakerEmbeddingStore: speakerEmbeddingStore)
        let retranscriptionService = RetranscriptionService(transcriptionService: transcriptionService)
        let keychainStore = InMemoryKeychainStore()
        let defaultsSuite = "AppStateTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
        userDefaults.removePersistentDomain(forName: defaultsSuite)
        let aiProviderStore = AIProviderStore(defaults: userDefaults)

        return ServiceContainer(
            main: MainServiceContainer(
                bookmarkStore: bookmarkStore,
                aiProviderService: AIProviderService(
                    keychainStore: keychainStore,
                    store: aiProviderStore
                ),
                audioDeviceService: AudioDeviceService(),
                appAudioService: AppAudioService(),
                permissionService: permissionService,
                transcriptExportService: TranscriptExportService()
            ),
            background: BackgroundServiceContainer(
                workspaceService: workspaceService,
                modelInstallService: ModelInstallService(workspaceService: workspaceService),
                recordingService: RecordingService(
                    workspaceService: workspaceService,
                    modelContainer: modelContainer
                ),
                transcriptionService: transcriptionService,
                retranscriptionService: retranscriptionService,
                audioImportService: AudioImportService(retranscriptionService: retranscriptionService),
                speakerEmbeddingStore: speakerEmbeddingStore
            )
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

private final class TestBookmarkStore: BookmarkStore, @unchecked Sendable {
    private var bookmarkData: Data?

    func loadWorkspaceBookmark() -> Data? {
        bookmarkData
    }

    func saveWorkspaceBookmark(_ data: Data) {
        bookmarkData = data
    }
}
