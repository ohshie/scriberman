import AppKit
import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
final class AppStateTests {
    private let modelContainer: ModelContainer

    init() throws {
        modelContainer = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
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
    func testAppDelegateSourceGuardsOnboardingBeforeFirstTimeTrayAlert() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let delegateFileURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AppDelegate.swift")
        let delegateSource = try String(contentsOf: delegateFileURL, encoding: .utf8)

        #expect(delegateSource.contains("if appState.requiredOnboardingStep != nil"))
        #expect(delegateSource.contains("NSApp.terminate(nil)"))
        #expect(delegateSource.contains("showFirstTimeTrayAlert(window: sender)"))
        #expect(delegateSource.contains("hasShownFirstTimeTrayAlert"))
    }

    @Test
    func testAppDelegateSourceRemembersCloseChoiceWhenRequested() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let delegateFileURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AppDelegate.swift")
        let delegateSource = try String(contentsOf: delegateFileURL, encoding: .utf8)

        #expect(delegateSource.contains("let rememberCheckbox = NSButton(checkboxWithTitle: \"Remember my choice\""))
        #expect(delegateSource.contains("let shouldRemember = rememberCheckbox.state == .on"))
        #expect(delegateSource.contains("appState.menuBarSettings.closeAction = keepInMenuBar ? .tray : .quit"))
    }

    @Test
    func testAppDelegateSourceDeclaresStatusItemRecordingMenuActions() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let delegateFileURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AppDelegate.swift")
        let delegateSource = try String(contentsOf: delegateFileURL, encoding: .utf8)

        #expect(delegateSource.contains("Start Recording"))
        #expect(delegateSource.contains("Record with…"))
        #expect(delegateSource.contains("Stop Recording"))
        #expect(delegateSource.contains("func menuNeedsUpdate"))
    }

    @Test
    func testApplicationShouldTerminateReturnsTerminateNowWhenIdle() {
        let delegate = AppDelegate()
        delegate.modelContext = modelContainer.mainContext
        delegate.isRecordingForLifecycleHandler = { false }

        let result = delegate.applicationShouldTerminate(NSApp)

        #expect(result == .terminateNow)
    }

    @Test
    func testApplicationShouldTerminateReturnsTerminateLaterAndStopsRecordingWhenRecording() async {
        let delegate = AppDelegate()
        delegate.modelContext = modelContainer.mainContext
        delegate.isRecordingForLifecycleHandler = { true }

        var stopCallCount = 0
        var didReplyToTerminate = false
        delegate.stopRecordingForLifecycleHandler = {
            stopCallCount += 1
        }
        delegate.terminationReplyHandler = { shouldTerminate in
            didReplyToTerminate = shouldTerminate
        }

        let result = delegate.applicationShouldTerminate(NSApp)

        #expect(result == .terminateLater)
        await assertEventuallyTrue("Expected stopRecording and termination reply to execute") {
            stopCallCount == 1 && didReplyToTerminate
        }
    }

    @Test
    func testApplicationShouldTerminateReturnsTerminateNowWhenModelContextIsNil() {
        let delegate = AppDelegate()
        delegate.modelContext = nil
        delegate.isRecordingForLifecycleHandler = { true }

        let result = delegate.applicationShouldTerminate(NSApp)

        #expect(result == .terminateNow)
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

    @Test
    func testPendingSessionFocusRequestConsumesOnce() {
        let permissionService = MockPermissionService()
        let services = makeServiceContainer(permissionService: permissionService)
        let appState = AppState(services: services)

        #expect(appState.consumePendingSessionFocusRequest() == false)
        appState.requestPendingSessionFocusFromMenuBar()
        #expect(appState.consumePendingSessionFocusRequest())
        #expect(appState.consumePendingSessionFocusRequest() == false)
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

        let appAudioSettings = AppAudioSettings(userDefaults: userDefaults)

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
                transcriptExportService: TranscriptExportService(),
                appAudioSettings: appAudioSettings
            ),
            background: BackgroundServiceContainer(
                workspaceService: workspaceService,
                modelInstallService: ModelInstallService(workspaceService: workspaceService),
                recordingService: RecordingService(
                    workspaceService: workspaceService,
                    modelContainer: modelContainer,
                    appAudioSettings: appAudioSettings
                ),
                transcriptionService: transcriptionService,
                retranscriptionService: retranscriptionService,
                audioImportService: AudioImportService(retranscriptionService: retranscriptionService),
                speakerEmbeddingStore: speakerEmbeddingStore
            )
        )
    }

    private func assertEventuallyTrue(
        _ message: String,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        predicate: @escaping @MainActor () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        let timeout = start + timeoutNanoseconds

        while DispatchTime.now().uptimeNanoseconds < timeout {
            if predicate() {
                return
            }

            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        let timeoutError = NSError(
            domain: "AppStateTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        Issue.record(timeoutError)
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
