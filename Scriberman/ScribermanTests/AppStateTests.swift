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

    @Test(.tags(.sourceLint))
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

    @Test(.tags(.sourceLint))
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

    @Test(.tags(.sourceLint))
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

    @Test(.tags(.sourceLint))
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

    @Test(.tags(.sourceLint))
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

    @Test(.tags(.sourceLint))
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

    @Test(.tags(.sourceLint))
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

    @Test(.tags(.sourceLint))
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
    func testApplicationShouldTerminateWaitsForFinalizationWithoutRecording() async {
        let delegate = AppDelegate()
        delegate.modelContext = modelContainer.mainContext
        delegate.isRecordingForLifecycleHandler = { false }
        let finalizer = FakeRecordingFinalizer(hasJobs: true)
        delegate.recordingFinalizer = finalizer

        var didReplyToTerminate = false
        delegate.terminationReplyHandler = { didReplyToTerminate = $0 }

        let result = delegate.applicationShouldTerminate(NSApp)

        #expect(result == .terminateLater)
        await assertEventuallyTrue("Expected quit to wait on the finalizer") {
            finalizer.waitCount == 1
        }
        #expect(!didReplyToTerminate)
        #expect(finalizer.lastTimeout == .seconds(15))

        finalizer.finish()
        await assertEventuallyTrue("Expected the termination reply after finalization") {
            didReplyToTerminate
        }
    }

    @Test
    func testApplicationShouldTerminateReturnsTerminateNowWithNoFinalizationWork() {
        let delegate = AppDelegate()
        delegate.modelContext = modelContainer.mainContext
        delegate.isRecordingForLifecycleHandler = { false }
        delegate.recordingFinalizer = FakeRecordingFinalizer(hasJobs: false)

        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
    }

    @Test
    func testWakeCleanupWaitsForInFlightPreSleepStop() async {
        let delegate = AppDelegate()
        delegate.modelContext = modelContainer.mainContext
        delegate.isRecordingForLifecycleHandler = { true }

        var stopCompleted = false
        var stopWasCompleteAtCleanup: Bool?
        delegate.stopRecordingForLifecycleHandler = {
            try? await Task.sleep(nanoseconds: 100_000_000)
            stopCompleted = true
        }
        delegate.wakeCleanupHandler = {
            stopWasCompleteAtCleanup = stopCompleted
        }

        delegate.handleWillSleep()
        delegate.handleDidWake()

        await assertEventuallyTrue("Expected wake cleanup to run after the stop completed") {
            stopWasCompleteAtCleanup != nil
        }
        // The handlers capture the delegate weakly; keep it alive through the wait, as the app does.
        withExtendedLifetime(delegate) {}
        #expect(stopWasCompleteAtCleanup == true)
    }

    @Test
    func testWakeCleanupRunsImmediatelyWithNoPendingStop() async {
        let delegate = AppDelegate()
        delegate.modelContext = modelContainer.mainContext

        var cleanupRan = false
        delegate.wakeCleanupHandler = {
            cleanupRan = true
        }

        delegate.handleDidWake()

        await assertEventuallyTrue("Expected wake cleanup to run") {
            cleanupRan
        }
        withExtendedLifetime(delegate) {}
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
    func testDiscardPendingSessionClearsPendingAndPreservesRecordingState() {
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
        guard case .recording = appState.newSessionViewModel.state else {
            Issue.record("Expected recording state to be preserved while an active recording is in progress")
            return
        }
    }

    @Test
    func testDiscardPendingSessionResetsNewSessionStateWhenIdle() {
        let permissionService = MockPermissionService()
        let services = makeServiceContainer(permissionService: permissionService)
        let appState = AppState(services: services)

        appState.selectPendingSession()
        appState.newSessionViewModel.state = .idle
        appState.discardPendingSession()

        #expect(appState.pendingSession == nil)
        guard case .idle = appState.newSessionViewModel.state else {
            Issue.record("Expected idle state after discarding a pending session while idle")
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

    @Test
    func readinessPreparesAfterOnboardingAndOncePerWorkspace() async {
        let permissions = MockPermissionService()
        permissions.verifyMicResult = true
        permissions.verifyScreenRecordingResult = true
        let first = Workspace(rootURL: URL(fileURLWithPath: "/tmp/readiness-first"))
        let second = Workspace(rootURL: URL(fileURLWithPath: "/tmp/readiness-second"))
        var prepared: [Workspace] = []
        var registrations = 0
        let appState = AppState(
            services: makeServiceContainer(permissionService: permissions),
            restoreWorkspaceHandler: { first },
            setWorkspaceHandler: { Workspace(rootURL: $0) },
            prepareDictationHandler: { prepared.append($0) },
            registerHotkeyHandler: { registrations += 1 }
        )
        await appState.bootstrapWorkspace()
        appState.applyReadiness()
        #expect(prepared.isEmpty)
        #expect(registrations == 0)

        appState.settingsViewModel.bundlePhase = .allReady
        appState.applyReadiness()
        await assertEventuallyTrue("Expected preparation after onboarding") { prepared == [first] }
        appState.applyReadiness()
        permissions.micStatus = .denied
        appState.applyReadiness()
        permissions.micStatus = .granted
        appState.applyReadiness()
        #expect(registrations == 1)

        await appState.selectWorkspace(url: second.rootURL)
        #expect(appState.requiredOnboardingStep == .models)
        appState.settingsViewModel.bundlePhase = .allReady
        appState.applyReadiness()
        await assertEventuallyTrue("Expected preparation for the new workspace") { prepared == [first, second] }
        #expect(registrations == 1)
    }

    @Test
    func failedWorkspaceSelectionPreservesWorkspaceAndReadiness() async {
        let original = Workspace(rootURL: URL(fileURLWithPath: "/tmp/original"))
        let appState = AppState(
            services: makeServiceContainer(permissionService: MockPermissionService()),
            restoreWorkspaceHandler: { original },
            setWorkspaceHandler: { _ in throw WorkspaceError.failedToCreateBookmark }
        )
        await appState.bootstrapWorkspace()
        appState.settingsViewModel.bundlePhase = .allReady
        await appState.selectWorkspace(url: URL(fileURLWithPath: "/tmp/candidate"))
        #expect(appState.workspace == original)
        #expect(appState.workspaceErrorMessage == WorkspaceError.failedToCreateBookmark.localizedDescription)
        #expect(appState.settingsViewModel.bundlePhase == .allReady)
    }

    @Test
    func workspaceSelectionIsBlockedDuringRecordingAndModelInstallation() async {
        var selections = 0
        let appState = AppState(
            services: makeServiceContainer(permissionService: MockPermissionService()),
            setWorkspaceHandler: { selections += 1; return Workspace(rootURL: $0) }
        )
        let url = URL(fileURLWithPath: "/tmp/candidate")
        #expect(appState.isWorkspaceChangeAllowed)
        appState.newSessionViewModel.state = .recording(duration: 1, level: 0)
        #expect(!appState.isWorkspaceChangeAllowed)
        await appState.selectWorkspace(url: url)
        appState.newSessionViewModel.state = .idle
        for phase in [BundleInstallPhase.downloading(label: "ASR", progress: 0.5), .warmingUp] {
            appState.settingsViewModel.bundlePhase = phase
            #expect(!appState.isWorkspaceChangeAllowed)
            await appState.selectWorkspace(url: url)
        }
        #expect(selections == 0)
        appState.settingsViewModel.bundlePhase = .allReady
        #expect(appState.isWorkspaceChangeAllowed)
        await appState.selectWorkspace(url: url)
        #expect(selections == 1)
    }

    @Test
    func workspaceSelectionIsBlockedUntilRetranscriptionFinishes() async {
        let appState = AppState(services: makeServiceContainer(permissionService: MockPermissionService()))
        let session = RecordingSession(createdAt: .now, duration: 1, micAudioURL: "/tmp/audio.wav", title: "Test", status: .recorded)
        session.mixdownURL = "/tmp/mixdown.wav"
        modelContainer.mainContext.insert(session)
        appState.jobsViewModel.reprocess(session: session, context: modelContainer.mainContext)
        #expect(!appState.isWorkspaceChangeAllowed)
        await assertEventuallyTrue("Expected busy state to clear after workspace failure") {
            appState.isWorkspaceChangeAllowed
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
                screenCaptureService: ScreenCaptureService(displayProvider: { [] }),
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
                speakerEmbeddingStore: speakerEmbeddingStore,
                recoveryService: RecordingRecoveryService(
                    workspaceService: workspaceService,
                    modelContainer: modelContainer
                ),
                recordingFinalizer: RecordingFinalizer(
                    mixdownCoordinator: RecordingMixdownCoordinator(workspaceService: workspaceService, modelContainer: modelContainer),
                    screenVideoMuxer: ScreenVideoMuxer(workspaceService: workspaceService, modelContainer: modelContainer)
                )
            )
        )
    }

    private func assertEventuallyTrue(
        _ message: String,
        // Generous because it returns as soon as the predicate holds; under the full parallel suite
        // the work being waited on can queue for seconds behind other tests.
        timeoutNanoseconds: UInt64 = 10_000_000_000,
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

/// Finalizer whose `waitForAll` returns only after `finish()`.
private final class FakeRecordingFinalizer: RecordingFinalizing, @unchecked Sendable {
    private let lock = NSLock()
    private let jobs: Bool
    private var waits = 0
    private var timeout: Duration?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    init(hasJobs: Bool) {
        jobs = hasJobs
    }

    var hasJobs: Bool { jobs }
    var waitCount: Int { lock.withLock { waits } }
    var lastTimeout: Duration? { lock.withLock { timeout } }

    func waitForAll(timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                waits += 1
                self.timeout = timeout
                if finished { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume(returning: true) }
        }
    }

    func finish() {
        let pending = lock.withLock {
            finished = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: true)
    }
}

struct WorkspaceTransitionTests {
    @Test(arguments: ["access", "folders", "bookmark", "success"])
    func candidateIsCommittedOnlyAfterPreparation(stage: String) async throws {
        let original = URL(fileURLWithPath: "/tmp/workspace-original")
        let candidate = URL(fileURLWithPath: "/tmp/workspace-candidate")
        let probe = WorkspaceAccessProbe()
        let store = TestBookmarkStore()
        let service = WorkspaceService(
            bookmarkStore: store,
            startAccess: { url in
                if url == candidate && stage == "access" { return false }
                probe.start(url)
                return true
            },
            stopAccess: { probe.stop($0) },
            createFolders: { workspace in
                if workspace.rootURL == candidate && stage == "folders" {
                    throw WorkspaceError.failedToCreateSubfolders
                }
            },
            createBookmark: { url in
                if url == candidate && stage == "bookmark" { throw WorkspaceError.failedToCreateBookmark }
                return Data(url.path.utf8)
            }
        )
        _ = try await service.setWorkspace(url: original)
        do {
            _ = try await service.setWorkspace(url: candidate)
            #expect(stage == "success")
        } catch {
            #expect(stage != "success")
        }
        let expected = stage == "success" ? candidate : original
        #expect(await service.currentWorkspace() == Workspace(rootURL: expected))
        #expect(store.loadWorkspaceBookmark() == Data(expected.path.utf8))
        #expect(probe.active == [expected])
    }
}

private final class WorkspaceAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: Set<URL> = []
    var active: Set<URL> { lock.withLock { urls } }
    func start(_ url: URL) { _ = lock.withLock { urls.insert(url) } }
    func stop(_ url: URL) { _ = lock.withLock { urls.remove(url) } }
}
