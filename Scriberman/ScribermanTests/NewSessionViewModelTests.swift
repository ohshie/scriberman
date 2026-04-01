import CoreAudio
import SwiftData
import XCTest
@testable import Scriberman

@MainActor
final class NewSessionViewModelTests: XCTestCase {
    private var workspaceService: MockWorkspaceService!
    private var recordingService: MockRecordingService!
    private var audioDeviceService: MockAudioDeviceService!
    private var appAudioService: MockNewSessionAppAudioService!
    private var permissionService: MockPermissionService!
    private var userDefaultsSuiteName: String!
    private var userDefaults: UserDefaults!
    private var viewModel: NewSessionViewModel!
    private var context: ModelContext!
    private var workspace: Workspace!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspaceService = MockWorkspaceService()
        recordingService = MockRecordingService()
        audioDeviceService = MockAudioDeviceService()
        appAudioService = MockNewSessionAppAudioService()
        permissionService = MockPermissionService()
        userDefaultsSuiteName = "NewSessionViewModelTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        workspace = Workspace(rootURL: URL(fileURLWithPath: "/tmp/workspace"))
        workspaceService.requireWritableResult = .success(workspace)

        let modelContainer = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(modelContainer)

        viewModel = NewSessionViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService,
            userDefaults: userDefaults
        )
    }

    override func tearDown() {
        viewModel = nil
        context = nil
        workspace = nil
        if let userDefaultsSuiteName {
            userDefaults?.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        userDefaultsSuiteName = nil
        userDefaults = nil
        permissionService = nil
        appAudioService = nil
        audioDeviceService = nil
        recordingService = nil
        workspaceService = nil
        super.tearDown()
    }

    func testStateMachineTransitionsIdleToRecordingToStopped() async throws {
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
            return XCTFail("Expected recording state after start")
        }

        let session = await viewModel.stopRecording(context: context)
        guard case .idle = viewModel.state else {
            return XCTFail("Expected idle state after stop")
        }
        XCTAssertEqual(session?.id, stoppedSession.id)
    }

    func testStartRecordingIncrementsUsageForSelectedDevice() async {
        permissionService.micStatus = .granted
        let selectedDevice = AudioInputDevice(id: 7, uid: "uid-7", name: "Desk Mic")
        audioDeviceService.availableDevices = [selectedDevice]
        audioDeviceService.selectedDevice = selectedDevice
        viewModel.selectedDevice = selectedDevice

        await viewModel.startRecording(title: "Session", context: context)

        XCTAssertEqual(audioDeviceService.incrementUsageCalls, ["uid-7"])
    }

    func testStartRecordingPassesTitleToService() async {
        permissionService.micStatus = .granted
        let customTitle = "Meeting with Team"
        
        await viewModel.startRecording(title: customTitle, context: context)
        
        XCTAssertEqual(recordingService.startCalls.count, 1)
        XCTAssertEqual(recordingService.startCalls.first?.title, customTitle)
    }

    func testResetReturnsIdleFromRecordingState() {
        viewModel.state = .recording(duration: 10, level: 0)

        viewModel.reset()

        guard case .idle = viewModel.state else {
            return XCTFail("Expected idle state after reset")
        }
    }

    func testCanRecordRequiresGrantedMicrophonePermission() {
        permissionService.micStatus = .notDetermined
        XCTAssertFalse(viewModel.canRecord)

        permissionService.micStatus = .denied
        XCTAssertFalse(viewModel.canRecord)

        permissionService.micStatus = .granted
        XCTAssertTrue(viewModel.canRecord)
    }

    func testCanRecordRequiresSelectedAppWhenAppAudioEnabled() {
        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        viewModel.recordAppAudio = true
        viewModel.selectedApp = nil
        XCTAssertFalse(viewModel.canRecord)

        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)
        viewModel.selectedApp = app
        XCTAssertTrue(viewModel.canRecord)
    }

    func testRecordAppAudioToggleRequestsScreenPermissionWhenNotGranted() {
        permissionService.screenRecordingStatus = .notDetermined

        viewModel.recordAppAudio = true

        XCTAssertEqual(permissionService.requestScreenRecordingCalls, 1)
        XCTAssertFalse(viewModel.recordAppAudio)
    }

    func testMicrophonePermissionPromptStateTracksMicStatus() {
        permissionService.micStatus = .notDetermined
        XCTAssertTrue(viewModel.shouldShowMicrophonePermissionPrompt)

        permissionService.micStatus = .denied
        XCTAssertTrue(viewModel.shouldShowMicrophonePermissionPrompt)

        permissionService.micStatus = .granted
        XCTAssertFalse(viewModel.shouldShowMicrophonePermissionPrompt)
    }

    func testPermissionStatusWarningTextReflectsMicAndScreenVerificationState() {
        permissionService.micStatus = .notDetermined
        XCTAssertEqual(
            viewModel.permissionStatusWarningText,
            "Microphone permission is not verified. Recording is unavailable until access is granted."
        )

        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .denied
        XCTAssertEqual(
            viewModel.permissionStatusWarningText,
            "Screen Recording permission verification failed. App audio capture may be unavailable until access is re-enabled in System Settings."
        )

        permissionService.screenRecordingStatus = .granted
        XCTAssertNil(viewModel.permissionStatusWarningText)
    }

    func testRequestMicrophonePermissionInvokesPermissionService() async {
        permissionService.requestMicResult = true
        permissionService.micStatus = .notDetermined

        await viewModel.requestMicrophonePermission()

        XCTAssertEqual(permissionService.requestMicCalls, 1)
        XCTAssertTrue(viewModel.microphonePermissionGranted)
    }

    func testRequestScreenRecordingPermissionInvokesPermissionService() {
        viewModel.requestScreenRecordingPermission()
        XCTAssertEqual(permissionService.requestScreenRecordingCalls, 1)
    }

    func testRecheckPermissionsInvokesCheckAndVerifyMethods() async {
        await viewModel.recheckPermissions()
        XCTAssertEqual(permissionService.checkAllCalls, 1)
        XCTAssertEqual(permissionService.verifyMicCalls, 1)
        XCTAssertEqual(permissionService.verifyScreenRecordingCalls, 1)
    }

    func testRefreshAudioDevicesOnAppearCallsAudioDeviceServiceRefresh() {
        viewModel.refreshAudioDevicesOnAppear()
        XCTAssertEqual(audioDeviceService.refreshDevicesCalls, 1)
    }

    func testRefreshAudioDevicesOnPanelExpandedCallsAudioDeviceServiceRefresh() {
        viewModel.refreshAudioDevicesOnPanelExpanded()
        XCTAssertEqual(audioDeviceService.refreshDevicesCalls, 1)
    }

    func testAppAudioToggleRemainsEnabledWhenScreenPermissionNotGranted() {
        permissionService.screenRecordingStatus = .denied
        XCTAssertTrue(viewModel.appAudioToggleEnabled)
    }

    func testAirPodsDisconnectScenarioUpdatesSelectedDeviceStateFromService() {
        let airPods = AudioInputDevice(id: 2, uid: "uid-airpods", name: "AirPods")
        let builtIn = AudioInputDevice(id: 1, uid: "uid-built-in", name: "Built-in Mic")
        audioDeviceService.availableDevices = [airPods, builtIn]
        audioDeviceService.selectedDevice = airPods
        XCTAssertEqual(viewModel.selectedDevice?.uid, "uid-airpods")

        // Simulate disconnect fallback emitted by AudioDeviceService.
        audioDeviceService.availableDevices = [builtIn]
        audioDeviceService.selectedDevice = builtIn
        XCTAssertEqual(viewModel.selectedDevice?.uid, "uid-built-in")

        // Simulate reconnect recovery emitted by AudioDeviceService.
        audioDeviceService.availableDevices = [airPods, builtIn]
        audioDeviceService.selectedDevice = airPods
        XCTAssertEqual(viewModel.selectedDevice?.uid, "uid-airpods")
    }

    func testNewSessionPanelShowsGrantMicrophoneAccessPrompt() throws {
        let source = try newSessionPanelSource()
        XCTAssertTrue(source.contains("if viewModel.shouldShowMicrophonePermissionPrompt"))
        XCTAssertTrue(source.contains("Grant Microphone Access"))
    }

    func testNewSessionPanelPromptRequestsMicPermissionViaViewModel() throws {
        let source = try newSessionPanelSource()
        XCTAssertTrue(source.contains("await viewModel.requestMicrophonePermission()"))
    }

    func testNewSessionPanelRefreshesAudioDevicesOnAppear() throws {
        let source = try newSessionPanelSource()
        XCTAssertTrue(source.contains("viewModel.refreshAudioDevicesOnAppear()"))
    }

    func testNewSessionPanelShowsPermissionStatusWarningBanner() throws {
        let source = try newSessionPanelSource()
        XCTAssertTrue(source.contains("if let permissionStatusWarningText = viewModel.permissionStatusWarningText"))
        XCTAssertTrue(source.contains("exclamationmark.triangle.fill"))
        XCTAssertTrue(source.contains("Re-check Permissions"))
        XCTAssertTrue(source.contains("Request Screen Access"))
        XCTAssertTrue(source.contains("Open Privacy Settings"))
    }

    func testRefreshAudioDevicesOnAppearPreparesLiveTranscriptionWithWorkspace() throws {
        let source = try newSessionViewModelSource()
        XCTAssertTrue(source.contains("if let workspace = await workspaceService.currentWorkspace()"))
        XCTAssertTrue(source.contains("await liveTranscriptionService.prepare(workspace: workspace)"))
    }

    func testInitializationFailureMessageDirectsUserToSettingsModels() throws {
        let source = try newSessionViewModelSource()
        XCTAssertTrue(source.contains("catch LiveTranscriptionError.initializationFailed"))
        XCTAssertTrue(source.contains("Open Settings → Models to install ASR and Speaker Diarization models."))
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

    func refreshRunningApps() {
        refreshCalls += 1
    }
}
