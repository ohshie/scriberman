import Combine
import CoreAudio
import XCTest
@testable import Scriberman

@MainActor
final class StudioViewModelTests: XCTestCase {
    private var workspaceService: MockWorkspaceService!
    private var recordingService: MockRecordingService!
    private var audioDeviceService: MockAudioDeviceService!
    private var appAudioService: MockAppAudioService!
    private var permissionService: MockPermissionService!
    private var viewModel: StudioViewModel!
    private var workspace: Workspace!

    override func setUp() {
        super.setUp()
        workspaceService = MockWorkspaceService()
        recordingService = MockRecordingService()
        audioDeviceService = MockAudioDeviceService()
        appAudioService = MockAppAudioService()
        permissionService = MockPermissionService()
        workspace = Workspace(rootURL: URL(fileURLWithPath: "/tmp/workspace"))
        workspaceService.requireWritableResult = .success(workspace)
        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService
        )
    }

    override func tearDown() {
        viewModel = nil
        workspace = nil
        permissionService = nil
        appAudioService = nil
        audioDeviceService = nil
        recordingService = nil
        workspaceService = nil
        super.tearDown()
    }

    func testSuccessfulStartTransitionsToRecordingState() async {
        recordingService.isRecordingOverride = false
        recordingService.audioLevelOverride = 0

        await viewModel.startRecording()

        guard case let .recording(duration, level) = viewModel.recordingState else {
            return XCTFail("Expected recording state")
        }
        XCTAssertGreaterThanOrEqual(duration, 0)
        XCTAssertEqual(level, 0)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(recordingService.startCalls.count, 1)
        XCTAssertNil(recordingService.startCalls.first?.micDeviceID)
        XCTAssertNil(recordingService.startCalls.first?.capturedAppName)
    }

    func testFailedStartSetsErrorAndStaysIdle() async {
        recordingService.startShouldThrow = MockStartError.failed

        await viewModel.startRecording()

        guard case .idle = viewModel.recordingState else {
            return XCTFail("Expected idle state")
        }
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testStopTransitionsToStoppedWithFifteenSecondCTA() async {
        let session = makeSession(status: .recorded)
        recordingService.stopReturns = session

        await viewModel.stopRecording()

        guard case let .stopped(stoppedSession, ctaSecondsRemaining) = viewModel.recordingState else {
            return XCTFail("Expected stopped state")
        }
        XCTAssertEqual(stoppedSession.id, session.id)
        XCTAssertEqual(ctaSecondsRemaining, 15)
    }

    func testConsumeCTAReturnsSessionAndResetsToIdle() async {
        let session = makeSession(status: .recorded)
        recordingService.stopReturns = session
        await viewModel.stopRecording()

        let consumed = viewModel.consumeSessionForTranscribeCTA()

        XCTAssertEqual(consumed?.id, session.id)
        guard case .idle = viewModel.recordingState else {
            return XCTFail("Expected idle state")
        }
    }

    func testClearStoppedCTANoOpOnIdle() {
        viewModel.clearStoppedCTAIfNeeded()

        guard case .idle = viewModel.recordingState else {
            return XCTFail("Expected idle state")
        }
    }

    func testInitialMicSelectionStateMirrorsAudioDeviceService() {
        let builtInMic = AudioInputDevice(id: 1, uid: "built-in", name: "Built-in Microphone")
        audioDeviceService.availableDevices = [builtInMic]
        audioDeviceService.selectedDevice = builtInMic

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService
        )

        XCTAssertEqual(viewModel.availableDevices, [builtInMic])
        XCTAssertEqual(viewModel.selectedDevice, builtInMic)
    }

    func testSelectingMicOnViewModelUpdatesAudioDeviceService() {
        let micA = AudioInputDevice(id: 1, uid: "mic-a", name: "Mic A")
        let micB = AudioInputDevice(id: 2, uid: "mic-b", name: "Mic B")
        audioDeviceService.availableDevices = [micA, micB]
        audioDeviceService.selectedDevice = micA

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService
        )

        viewModel.selectedDevice = micB

        XCTAssertEqual(audioDeviceService.selectedDevice, micB)
    }

    func testViewModelTracksAudioDeviceServiceSelectionChanges() {
        let micA = AudioInputDevice(id: 1, uid: "mic-a", name: "Mic A")
        let micB = AudioInputDevice(id: 2, uid: "mic-b", name: "Mic B")
        audioDeviceService.availableDevices = [micA, micB]

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService
        )

        audioDeviceService.selectedDevice = micB

        XCTAssertEqual(viewModel.selectedDevice, micB)
    }

    func testStartRecordingPassesSelectedMicDeviceID() async {
        let selected = AudioInputDevice(id: 42, uid: "usb-mic", name: "USB Mic")
        audioDeviceService.availableDevices = [selected]
        audioDeviceService.selectedDevice = selected

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService
        )

        await viewModel.startRecording()

        XCTAssertEqual(recordingService.startCalls.count, 1)
        XCTAssertEqual(recordingService.startCalls.first?.micDeviceID, selected.id)
    }

    func testRefreshAppsDelegatesToAppAudioService() {
        viewModel.refreshApps()
        XCTAssertEqual(appAudioService.refreshCalls, 1)
    }

    func testStartRecordingWithSelectedAppPassesAppContext() async {
        let selectedMic = AudioInputDevice(id: 1, uid: "mic-1", name: "Mic")
        let selectedApp = CapturedApp(bundleID: "com.test.zoom", name: "Zoom", pid: 333, icon: nil)
        audioDeviceService.availableDevices = [selectedMic]
        audioDeviceService.selectedDevice = selectedMic
        appAudioService.runningApps = [selectedApp]
        appAudioService.selectedApp = selectedApp
        permissionService.screenRecordingStatus = .granted

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService
        )

        await viewModel.startRecording()

        XCTAssertEqual(recordingService.startCalls.first?.micDeviceID, selectedMic.id)
        XCTAssertEqual(recordingService.startCalls.first?.capturedAppName, "Zoom")
        XCTAssertEqual(recordingService.startCalls.first?.appProcessID, 333)
    }

    func testStartRecordingFallsBackToMicOnlyWhenAppStartAttemptFails() async {
        let selectedMic = AudioInputDevice(id: 1, uid: "mic-1", name: "Mic")
        let selectedApp = CapturedApp(bundleID: "com.test.zoom", name: "Zoom", pid: 333, icon: nil)
        audioDeviceService.availableDevices = [selectedMic]
        audioDeviceService.selectedDevice = selectedMic
        appAudioService.runningApps = [selectedApp]
        appAudioService.selectedApp = selectedApp
        permissionService.screenRecordingStatus = .granted
        recordingService.startThrowSequence = [MockStartError.failed]

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService
        )

        await viewModel.startRecording()

        XCTAssertEqual(recordingService.startCalls.count, 2)
        XCTAssertEqual(recordingService.startCalls.first?.appProcessID, 333)
        XCTAssertEqual(recordingService.startCalls.first?.capturedAppName, "Zoom")
        XCTAssertNil(recordingService.startCalls.last?.appProcessID)
        XCTAssertNil(recordingService.startCalls.last?.capturedAppName)
        XCTAssertEqual(viewModel.errorMessage, "App audio capture unavailable. Enable Scriberman in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch app. Falling back to microphone-only recording.")
        guard case .recording = viewModel.recordingState else {
            return XCTFail("Expected recording state")
        }
    }

    func testStartRecordingFallsBackToDefaultMicWhenSelectedMicStartFails() async {
        let selectedMic = AudioInputDevice(id: 42, uid: "usb-mic", name: "USB Mic")
        audioDeviceService.availableDevices = [selectedMic]
        audioDeviceService.selectedDevice = selectedMic
        recordingService.startThrowSequence = [MockStartError.failed]

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService
        )

        await viewModel.startRecording()

        XCTAssertEqual(recordingService.startCalls.count, 2)
        XCTAssertEqual(recordingService.startCalls.first?.micDeviceID, 42)
        XCTAssertNil(recordingService.startCalls.last?.micDeviceID)
        XCTAssertEqual(viewModel.errorMessage, "Selected microphone unavailable. Falling back to system default microphone.")
        guard case .recording = viewModel.recordingState else {
            return XCTFail("Expected recording state")
        }
    }

    func testStartRecordingSkipsAppCaptureWhenSelectedAppDisappearsOnRefresh() async {
        let selectedMic = AudioInputDevice(id: 1, uid: "mic-1", name: "Mic")
        let selectedApp = CapturedApp(bundleID: "com.test.zoom", name: "Zoom", pid: 333, icon: nil)
        audioDeviceService.availableDevices = [selectedMic]
        audioDeviceService.selectedDevice = selectedMic
        appAudioService.runningApps = [selectedApp]
        appAudioService.selectedApp = selectedApp
        appAudioService.onRefresh = { [weak appAudioService] in
            appAudioService?.runningApps = []
            appAudioService?.selectedApp = nil
        }

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService
        )

        await viewModel.startRecording()

        XCTAssertEqual(appAudioService.refreshCalls, 1)
        XCTAssertNil(recordingService.startCalls.first?.appProcessID)
        XCTAssertNil(recordingService.startCalls.first?.capturedAppName)
    }

    func testStartRecordingRequestsAppAudioPermissionAndFallsBackWhenDenied() async {
        let selectedMic = AudioInputDevice(id: 1, uid: "mic-1", name: "Mic")
        let selectedApp = CapturedApp(bundleID: "com.test.zoom", name: "Zoom", pid: 333, icon: nil)
        audioDeviceService.availableDevices = [selectedMic]
        audioDeviceService.selectedDevice = selectedMic
        appAudioService.runningApps = [selectedApp]
        appAudioService.selectedApp = selectedApp
        permissionService.screenRecordingStatus = .denied

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService
        )

        await viewModel.startRecording()

        XCTAssertNil(recordingService.startCalls.first?.appProcessID)
        XCTAssertNil(recordingService.startCalls.first?.capturedAppName)
        XCTAssertEqual(viewModel.errorMessage, "App audio capture permission denied. Enable Scriberman in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch app. Falling back to microphone-only recording.")
    }

    func testRecordingMonitorSurfacesPendingInterruptionError() async {
        recordingService.isRecordingOverride = false
        recordingService.pendingError = .captureInterrupted

        await viewModel.startRecording()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(viewModel.errorMessage, RecordingError.captureInterrupted.localizedDescription)
    }

    func testAppAudioToggleEnabledTracksScreenRecordingStatus() {
        permissionService.screenRecordingStatus = .denied

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            permissionService: permissionService
        )

        XCTAssertFalse(viewModel.appAudioToggleEnabled)

        permissionService.screenRecordingStatus = .granted

        XCTAssertTrue(viewModel.appAudioToggleEnabled)
    }

    private func makeSession(status: RecordingStatus) -> RecordingSession {
        RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 12,
            micAudioURL: "/tmp/audio.wav",
            title: "Session",
            status: status
        )
    }
}

enum MockStartError: LocalizedError {
    case failed

    var errorDescription: String? {
        switch self {
        case .failed:
            return "start failed"
        }
    }
}

@MainActor
private final class MockAppAudioService: AppAudioServiceProtocol {
    @Published var runningApps: [CapturedApp] = []
    @Published var selectedApp: CapturedApp?
    var refreshCalls = 0
    var onRefresh: (() -> Void)?

    var runningAppsPublisher: AnyPublisher<[CapturedApp], Never> {
        $runningApps.eraseToAnyPublisher()
    }

    var selectedAppPublisher: AnyPublisher<CapturedApp?, Never> {
        $selectedApp.eraseToAnyPublisher()
    }

    func refreshRunningApps() {
        refreshCalls += 1
        onRefresh?()
    }
}
