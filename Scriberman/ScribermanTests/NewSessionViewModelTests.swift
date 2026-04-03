import Foundation
import CoreAudio
import SwiftData
import Testing
@testable import Scriberman

@MainActor
struct NewSessionViewModelTests {
    private typealias Fixture = (
        workspaceService: MockWorkspaceService,
        recordingService: MockRecordingService,
        audioDeviceService: MockAudioDeviceService,
        appAudioService: MockNewSessionAppAudioService,
        permissionService: MockPermissionService,
        viewModel: NewSessionViewModel,
        context: ModelContext,
        cleanup: () -> Void
    )

    private func makeFixture() -> Fixture {
        let workspaceService = MockWorkspaceService()
        let recordingService = MockRecordingService()
        let audioDeviceService = MockAudioDeviceService()
        let appAudioService = MockNewSessionAppAudioService()
        let permissionService = MockPermissionService()
        let userDefaultsSuiteName = "NewSessionViewModelTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuiteName) ?? .standard
        let workspace = Workspace(rootURL: URL(fileURLWithPath: "/tmp/workspace"))
        workspaceService.requireWritableResult = .success(workspace)

        let modelContainer = try! ModelContainer(
            for: RecordingSession.self, ImportedSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(modelContainer)

        let viewModel = NewSessionViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService,
            userDefaults: userDefaults
        )

        return (
            workspaceService,
            recordingService,
            audioDeviceService,
            appAudioService,
            permissionService,
            viewModel,
            context,
            { userDefaults.removePersistentDomain(forName: userDefaultsSuiteName) }
        )
    }

    @Test
    func testStateMachineTransitionsIdleToRecordingToStopped() async throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        recordingService.isRecordingOverride = false
        recordingService.audioLevelOverride = 0
        let stoppedSession = RecordingSession(
            createdAt: .now,
            duration: 3,
            micAudioURL: "/tmp/test.wav",
            title: "Recorded",
            status: .recorded
        )
        context.insert(stoppedSession)
        try context.save()
        recordingService.stopReturns = stoppedSession.id

        await viewModel.startRecording(title: "Session", context: context)
        guard case .recording = viewModel.state else {
            Issue.record("Expected recording state after start")
            return
        }

        let session = await viewModel.stopRecording(context: context)
        guard case .idle = viewModel.state else {
            Issue.record("Expected idle state after stop")
            return
        }
        #expect(session?.id == stoppedSession.id)
    }

    @Test
    func testStartRecordingIncrementsUsageForSelectedDevice() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.micStatus = .granted
        let selectedDevice = AudioInputDevice(id: 7, uid: "uid-7", name: "Desk Mic")
        audioDeviceService.availableDevices = [selectedDevice]
        audioDeviceService.selectedDevice = selectedDevice
        viewModel.selectedDevice = selectedDevice

        await viewModel.startRecording(title: "Session", context: context)

        #expect(audioDeviceService.incrementUsageCalls == ["uid-7"])
    }

    @Test
    func testStartRecordingIncrementsUsageForSelectedApp() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)
        appAudioService.runningApps = [app]
        viewModel.selectApp(app)

        await viewModel.startRecording(title: "Session", context: context)

        #expect(appAudioService.incrementUsageCalls == ["com.apple.Music"])
    }

    @Test
    func testStartRecordingPassesTitleToService() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.micStatus = .granted
        let customTitle = "Meeting with Team"
        
        await viewModel.startRecording(title: customTitle, context: context)
        
        #expect(recordingService.startCalls.count == 1)
        #expect(recordingService.startCalls.first?.title == customTitle)
    }

    @Test
    func testResetReturnsIdleFromRecordingState() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        viewModel.state = .recording(duration: 10, level: 0)

        viewModel.reset()

        guard case .idle = viewModel.state else {
            Issue.record("Expected idle state after reset")
            return
        }
    }

    @Test
    func testIsIdleIsTrueWhenStateIsIdle() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        viewModel.state = .idle

        #expect(viewModel.isIdle)
    }

    @Test
    func testIsIdleIsFalseWhenRecording() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        viewModel.state = .recording(duration: 1, level: 0.5)

        #expect(!(viewModel.isIdle))
    }

    @Test
    func testCanRecordRequiresGrantedMicrophonePermission() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.micStatus = .notDetermined
        #expect(!(viewModel.canRecord))

        permissionService.micStatus = .denied
        #expect(!(viewModel.canRecord))

        permissionService.micStatus = .granted
        #expect(viewModel.canRecord)
    }

    @Test
    func testCanRecordRequiresSelectedAppWhenAppAudioEnabled() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        viewModel.recordAppAudio = true
        viewModel.selectedApp = nil
        #expect(!(viewModel.canRecord))

        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)
        viewModel.selectedApp = app
        #expect(viewModel.canRecord)
    }

    @Test
    func testRecordAppAudioToggleRequestsScreenPermissionWhenNotGranted() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.screenRecordingStatus = .notDetermined

        viewModel.recordAppAudio = true

        #expect(permissionService.requestScreenRecordingCalls == 1)
        #expect(!(viewModel.recordAppAudio))
    }

    @Test
    func testSelectAppSetsSelectedAppAndEnablesAppAudioWhenPermissionGranted() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.screenRecordingStatus = .granted
        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)
        appAudioService.runningApps = [app]

        viewModel.selectApp(app)

        #expect(viewModel.selectedApp?.bundleID == "com.apple.Music")
        #expect(viewModel.recordAppAudio)
    }

    @Test
    func testSelectAppNilDisablesAppAudioAndClearsSelection() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.screenRecordingStatus = .granted
        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)
        appAudioService.runningApps = [app]
        viewModel.selectApp(app)

        viewModel.selectApp(nil)

        #expect(!(viewModel.recordAppAudio))
        #expect(viewModel.selectedApp == nil)
    }

    @Test
    func testSelectAppRequestsPermissionWhenNotGranted() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.screenRecordingStatus = .denied
        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)

        viewModel.selectApp(app)

        #expect(permissionService.requestScreenRecordingCalls == 1)
        #expect(!(viewModel.recordAppAudio))
        #expect(viewModel.selectedApp == nil)
    }

    @Test
    func testMicrophonePermissionPromptStateTracksMicStatus() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.micStatus = .notDetermined
        #expect(viewModel.shouldShowMicrophonePermissionPrompt)

        permissionService.micStatus = .denied
        #expect(viewModel.shouldShowMicrophonePermissionPrompt)

        permissionService.micStatus = .granted
        #expect(!(viewModel.shouldShowMicrophonePermissionPrompt))
    }

    @Test
    func testPermissionStatusWarningTextReflectsMicAndScreenVerificationState() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.micStatus = .notDetermined
        #expect(
            viewModel.permissionStatusWarningText
                == "Microphone permission is not verified. Recording is unavailable until access is granted."
        )

        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .denied
        #expect(
            viewModel.permissionStatusWarningText
                == "Screen Recording permission verification failed. App audio capture may be unavailable until access is re-enabled in System Settings."
        )

        permissionService.screenRecordingStatus = .granted
        #expect(viewModel.permissionStatusWarningText == nil)
    }

    @Test
    func testRequestMicrophonePermissionInvokesPermissionService() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.requestMicResult = true
        permissionService.micStatus = .notDetermined

        await viewModel.requestMicrophonePermission()

        #expect(permissionService.requestMicCalls == 1)
        #expect(viewModel.microphonePermissionGranted)
    }

    @Test
    func testRequestScreenRecordingPermissionInvokesPermissionService() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        viewModel.requestScreenRecordingPermission()
        #expect(permissionService.requestScreenRecordingCalls == 1)
    }

    @Test
    func testRecheckPermissionsInvokesCheckAndVerifyMethods() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        await viewModel.recheckPermissions()
        #expect(permissionService.checkAllCalls == 1)
        #expect(permissionService.verifyMicCalls == 1)
        #expect(permissionService.verifyScreenRecordingCalls == 1)
    }

    @Test
    func testRefreshAudioDevicesOnAppearCallsAudioDeviceServiceRefresh() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        viewModel.refreshAudioDevicesOnAppear()
        #expect(audioDeviceService.refreshDevicesCalls == 1)
    }

    @Test
    func testRefreshAudioDevicesOnPanelExpandedCallsAudioDeviceServiceRefresh() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        viewModel.refreshAudioDevicesOnPanelExpanded()
        #expect(audioDeviceService.refreshDevicesCalls == 1)
    }

    @Test
    func testAppAudioToggleRemainsEnabledWhenScreenPermissionNotGranted() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        permissionService.screenRecordingStatus = .denied
        #expect(viewModel.appAudioToggleEnabled)
    }

    @Test
    func testAirPodsDisconnectScenarioUpdatesSelectedDeviceStateFromService() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        let airPods = AudioInputDevice(id: 2, uid: "uid-airpods", name: "AirPods")
        let builtIn = AudioInputDevice(id: 1, uid: "uid-built-in", name: "Built-in Mic")
        audioDeviceService.availableDevices = [airPods, builtIn]
        audioDeviceService.selectedDevice = airPods
        #expect(viewModel.selectedDevice?.uid == "uid-airpods")

        // Simulate disconnect fallback emitted by AudioDeviceService.
        audioDeviceService.availableDevices = [builtIn]
        audioDeviceService.selectedDevice = builtIn
        #expect(viewModel.selectedDevice?.uid == "uid-built-in")

        // Simulate reconnect recovery emitted by AudioDeviceService.
        audioDeviceService.availableDevices = [airPods, builtIn]
        audioDeviceService.selectedDevice = airPods
        #expect(viewModel.selectedDevice?.uid == "uid-airpods")
    }

    @Test
    func testNewSessionPanelShowsGrantMicrophoneAccessPrompt() throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        let source = try newSessionPanelSource()
        #expect(source.contains("if viewModel.shouldShowMicrophonePermissionPrompt"))
        #expect(source.contains("Grant Microphone Access"))
    }

    @Test
    func testNewSessionPanelPromptRequestsMicPermissionViaViewModel() throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        let source = try newSessionPanelSource()
        #expect(source.contains("await viewModel.requestMicrophonePermission()"))
    }

    @Test
    func testNewSessionPanelRefreshesAudioDevicesOnAppear() throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        let source = try newSessionPanelSource()
        #expect(source.contains("viewModel.refreshAudioDevicesOnAppear()"))
    }

    @Test
    func testNewSessionPanelShowsPermissionStatusWarningBanner() throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        let source = try newSessionPanelSource()
        #expect(source.contains("if let permissionStatusWarningText = viewModel.permissionStatusWarningText"))
        #expect(source.contains("exclamationmark.triangle.fill"))
        #expect(source.contains("Re-check Permissions"))
        #expect(source.contains("Request Screen Access"))
        #expect(source.contains("Open Privacy Settings"))
    }

    @Test
    func testRefreshAudioDevicesOnAppearPreparesLiveTranscriptionWithWorkspace() throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        let source = try newSessionViewModelSource()
        #expect(source.contains("if let workspace = await workspaceService.currentWorkspace()"))
        #expect(source.contains("await liveTranscriptionService.prepare(workspace: workspace)"))
    }

    @Test
    func testInitializationFailureMessageDirectsUserToSettingsModels() throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }

        let source = try newSessionViewModelSource()
        #expect(source.contains("catch LiveTranscriptionError.initializationFailed"))
        #expect(source.contains("Open Settings → Models to install ASR and Speaker Diarization models."))
    }

    private func newSessionPanelSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../UI/NewSessionPanelView.swift")
    }

    private func newSessionViewModelSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../ViewModels/NewSessionViewModel.swift")
    }

    private func readSourceFile(relativePathFromTests: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent(relativePathFromTests)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}

@MainActor
private final class MockNewSessionAppAudioService: AppAudioServiceProtocol {
    var runningApps: [CapturedApp] = []
    var selectedApp: CapturedApp?
    var refreshCalls = 0
    var incrementUsageCalls: [String] = []

    func incrementUsage(for bundleID: String) {
        incrementUsageCalls.append(bundleID)
    }

    func refreshRunningApps() {
        refreshCalls += 1
    }
}
