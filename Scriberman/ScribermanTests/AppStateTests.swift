import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
final class AppStateTests {
    private let modelContainer: ModelContainer

    init() throws {
        modelContainer = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @Test
    func testIsBootstrappingIsTrueInitially() {
        let appState = AppState(services: makeServiceContainer(permissionService: MockPermissionService()))
        #expect(appState.isBootstrapping)
    }

    @Test
    func testIsBootstrappingIsFalseAfterBootstrapWorkspaceCompletes() async {
        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true))
        let appState = AppState(
            services: makeServiceContainer(permissionService: MockPermissionService()),
            restoreWorkspaceHandler: { workspace }
        )

        await appState.bootstrapWorkspace()

        #expect(!(appState.isBootstrapping))
    }

    @Test
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
        appState.settingsViewModel.bundlePhase = BundleInstallPhase.allReady

        #expect(appState.requiredOnboardingStep == nil)
    }

    @Test
    func testRequiredOnboardingStepPrioritizesScreenRecording() {
        let permissionService = MockPermissionService()
        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .denied
        let appState = AppState(services: makeServiceContainer(permissionService: permissionService))
        appState.settingsViewModel.bundlePhase = BundleInstallPhase.allReady

        #expect(appState.requiredOnboardingStep == .screenRecording)
    }

    @Test
    func testRequiredOnboardingStepReturnsMicrophoneWhenScreenRecordingGranted() {
        let permissionService = MockPermissionService()
        permissionService.micStatus = .denied
        permissionService.screenRecordingStatus = .granted
        let appState = AppState(services: makeServiceContainer(permissionService: permissionService))
        appState.settingsViewModel.bundlePhase = BundleInstallPhase.allReady

        #expect(appState.requiredOnboardingStep == .microphone)
    }

    @Test
    func testRequiredOnboardingStepReturnsWorkspaceWhenPermissionsGranted() {
        let permissionService = MockPermissionService()
        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        let appState = AppState(services: makeServiceContainer(permissionService: permissionService))
        appState.settingsViewModel.bundlePhase = BundleInstallPhase.allReady

        #expect(appState.requiredOnboardingStep == .workspace)
    }

    @Test
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
        appState.settingsViewModel.bundlePhase = BundleInstallPhase.idle

        #expect(appState.requiredOnboardingStep == OnboardingStep.models)
    }

    @Test
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

        #expect(permissionService.checkAllCalls == 1)
        #expect(permissionService.verifyMicCalls == 1)
        #expect(permissionService.verifyScreenRecordingCalls == 1)
        #expect(appState.workspace == workspace)
    }

    @Test
    func testRefreshPermissionsOnActivationPerformsStrictVerification() async {
        let permissionService = MockPermissionService()
        let services = makeServiceContainer(permissionService: permissionService)
        let appState = AppState(services: services)

        await appState.refreshPermissionsOnActivation()

        #expect(permissionService.checkAllCalls == 1)
        #expect(permissionService.verifyMicCalls == 1)
        #expect(permissionService.verifyScreenRecordingCalls == 1)
    }

    @Test
    func testAppSourceDeclaresSettingsScene() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appFileURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("ScribermanApp.swift")
        let appSource = try String(contentsOf: appFileURL, encoding: .utf8)

        #expect(
            appSource.contains("Settings {"),
            "Expected ScribermanApp.swift to declare a SwiftUI Settings scene."
        )
    }

    @Test
    func testAppSourceDeclaresApplicationDelegateAdaptor() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appFileURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("ScribermanApp.swift")
        let appSource = try String(contentsOf: appFileURL, encoding: .utf8)

        #expect(
            appSource.contains("@NSApplicationDelegateAdaptor(AppDelegate.self)"),
            "Expected ScribermanApp.swift to declare AppDelegate adaptor."
        )
        #expect(
            appSource.contains("appDelegate.appState = appState"),
            "Expected ScribermanApp.swift to inject appState into AppDelegate."
        )
    }

    @Test
    func testAppSourceDeclaresMenuBarExtraScene() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appFileURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("ScribermanApp.swift")
        let appSource = try String(contentsOf: appFileURL, encoding: .utf8)

        #expect(
            appSource.contains("MenuBarExtra("),
            "Expected ScribermanApp.swift to declare a MenuBarExtra scene."
        )
        #expect(
            appSource.contains("MenuBarExtraView(appState: appState)"),
            "Expected ScribermanApp.swift to use MenuBarExtraView."
        )
    }

    @Test
    func testMenuBarExtraViewSourceDeclaresRecordWithSections() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let viewFileURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("UI/MenuBarExtraView.swift")
        let viewSource = try String(contentsOf: viewFileURL, encoding: .utf8)

        #expect(viewSource.contains("Menu(\"Record with…\")"))
        #expect(viewSource.contains("Text(\"Microphone\")"))
        #expect(viewSource.contains("Text(\"App Audio\")"))
        #expect(viewSource.contains("No App Audio"))
    }

    @Test
    func testSettingsViewSourceDeclaresMenuBarTab() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let viewFileURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("UI/SettingsView.swift")
        let viewSource = try String(contentsOf: viewFileURL, encoding: .utf8)

        #expect(viewSource.contains("case menuBar"))
        #expect(viewSource.contains("Label(\"Menu Bar\", systemImage: \"menubar.rectangle\")"))
        #expect(viewSource.contains("MenuBarSettingsView("))
    }

    @Test
    func testMenuBarSettingsViewSourceDeclaresCloseActionAndReset() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let viewFileURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("UI/MenuBarSettingsView.swift")
        let viewSource = try String(contentsOf: viewFileURL, encoding: .utf8)

        #expect(viewSource.contains("Picker(\"When closing main window\""))
        #expect(viewSource.contains("MenuBarSettings.CloseAction.ask"))
        #expect(viewSource.contains("MenuBarSettings.CloseAction.tray"))
        #expect(viewSource.contains("MenuBarSettings.CloseAction.quit"))
        #expect(viewSource.contains("Button(\"Reset to Defaults\")"))
        #expect(viewSource.contains("return \"System Default\""))
        #expect(viewSource.contains("return \"None\""))
    }

    @Test
    func testSelectPendingSessionCreatesSinglePendingSession() {
        let permissionService = MockPermissionService()
        let services = makeServiceContainer(permissionService: permissionService)
        let appState = AppState(services: services)

        appState.selectPendingSession()
        let firstPending = appState.pendingSession
        appState.selectPendingSession()

        #expect(firstPending != nil)
        #expect(appState.pendingSession?.id == firstPending?.id)
    }

    @Test
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

        #expect(appState.pendingSession == nil)
        guard case .idle = appState.newSessionViewModel.state else {
            Issue.record("Expected new session state to reset to idle")
            return
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
