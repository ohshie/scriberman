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
        XCTAssertEqual(permissionService.verifyMicCalls, 1)
        XCTAssertEqual(permissionService.verifyScreenRecordingCalls, 1)
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
        XCTAssertFalse(appState.showPermissionsOnboarding)
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

    func testPermissionsOnboardingRequiresBothStepsVerifiedForInteractiveDismiss() throws {
        let source = try permissionsOnboardingSource()
        XCTAssertTrue(
            source.contains(".interactiveDismissDisabled(!allStepsVerified)"),
            "Onboarding sheet should remain non-dismissible until both steps are verified."
        )
    }

    func testPermissionsOnboardingTracksStepVerificationState() throws {
        let source = try permissionsOnboardingSource()
        XCTAssertTrue(source.contains("@State private var micVerified = false"))
        XCTAssertTrue(source.contains("@State private var screenRecordingVerified = false"))
    }

    func testPermissionsOnboardingIncludesVerifyButtonsForBothSteps() throws {
        let source = try permissionsOnboardingSource()
        XCTAssertTrue(
            source.contains("Button(\"Verify\") {"),
            "Both onboarding steps should expose explicit Verify actions."
        )
        XCTAssertTrue(
            source.contains("await permissionService.verifyMic()"),
            "Microphone step should call verifyMic()."
        )
        XCTAssertTrue(
            source.contains("await permissionService.verifyScreenRecording()"),
            "Screen recording step should call verifyScreenRecording()."
        )
    }

    func testPermissionsOnboardingLocksScreenStepUntilMicVerified() throws {
        let source = try permissionsOnboardingSource()
        XCTAssertTrue(
            source.contains("Text(\"Step 2 is locked until microphone access is verified.\")"),
            "Screen step lock messaging should be visible while mic is unverified."
        )
        XCTAssertTrue(
            source.contains("if verified {\n            infoMessage = nil\n            currentStep = .screenRecording"),
            "Flow should only advance to screen step after mic verification succeeds."
        )
    }

    func testPermissionsOnboardingAutoVerifiesGrantedPermissions() throws {
        let source = try permissionsOnboardingSource()
        XCTAssertTrue(source.contains("await autoVerifyMicIfPossible()"))
        XCTAssertTrue(source.contains("await autoVerifyScreenRecordingIfPossible()"))
    }

    func testPermissionsOnboardingProvidesQuitEscapeHatchWithoutSkipAll() throws {
        let source = try permissionsOnboardingSource()
        XCTAssertFalse(source.contains("Button(\"Skip All\")"))
        XCTAssertFalse(source.contains("skipAll()"))
        XCTAssertTrue(source.contains("Button(\"Quit Scriberman\")"))
        XCTAssertTrue(source.contains("NSApp.terminate(nil)"))
    }

    private func permissionsOnboardingSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../UI/PermissionsOnboardingView.swift")
    }

    private func readSourceFile(relativePathFromTests: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent(relativePathFromTests)
        return try String(contentsOf: fileURL, encoding: .utf8)
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
