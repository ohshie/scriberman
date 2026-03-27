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
    private var appAudioPermissionService: MockAppAudioPermissionService!
    private var aggregateDeviceBuilder: MockAggregateDeviceBuilder!
    private var viewModel: StudioViewModel!
    private var workspace: Workspace!

    override func setUp() {
        super.setUp()
        workspaceService = MockWorkspaceService()
        recordingService = MockRecordingService()
        audioDeviceService = MockAudioDeviceService()
        appAudioService = MockAppAudioService()
        appAudioPermissionService = MockAppAudioPermissionService()
        aggregateDeviceBuilder = MockAggregateDeviceBuilder()
        workspace = Workspace(rootURL: URL(fileURLWithPath: "/tmp/workspace"))
        workspaceService.requireWritableResult = .success(workspace)
        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            appAudioPermissionService: appAudioPermissionService,
            aggregateDeviceBuilder: aggregateDeviceBuilder
        )
    }

    override func tearDown() {
        viewModel = nil
        workspace = nil
        aggregateDeviceBuilder = nil
        appAudioPermissionService = nil
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
            appAudioPermissionService: appAudioPermissionService,
            aggregateDeviceBuilder: aggregateDeviceBuilder
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
            appAudioPermissionService: appAudioPermissionService,
            aggregateDeviceBuilder: aggregateDeviceBuilder
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
            appAudioPermissionService: appAudioPermissionService,
            aggregateDeviceBuilder: aggregateDeviceBuilder
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
            appAudioPermissionService: appAudioPermissionService,
            aggregateDeviceBuilder: aggregateDeviceBuilder
        )

        await viewModel.startRecording()

        XCTAssertEqual(recordingService.startCalls.count, 1)
        XCTAssertEqual(recordingService.startCalls.first?.micDeviceID, selected.id)
    }

    func testRefreshAppsDelegatesToAppAudioService() {
        viewModel.refreshApps()
        XCTAssertEqual(appAudioService.refreshCalls, 1)
    }

    func testStartRecordingWithSelectedAppCreatesTapAndAggregate() async {
        let selectedMic = AudioInputDevice(id: 1, uid: "mic-1", name: "Mic")
        let selectedApp = CapturedApp(bundleID: "com.test.zoom", name: "Zoom", pid: 333, icon: nil)
        audioDeviceService.availableDevices = [selectedMic]
        audioDeviceService.selectedDevice = selectedMic
        appAudioService.runningApps = [selectedApp]
        appAudioService.selectedApp = selectedApp
        aggregateDeviceBuilder.tapResult = 77
        aggregateDeviceBuilder.aggregateResult = 88

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            appAudioPermissionService: appAudioPermissionService,
            aggregateDeviceBuilder: aggregateDeviceBuilder
        )

        await viewModel.startRecording()

        XCTAssertEqual(aggregateDeviceBuilder.createTapPIDs, [333])
        XCTAssertEqual(aggregateDeviceBuilder.createAggregateInputs.first?.micUID, "mic-1")
        XCTAssertEqual(recordingService.startCalls.first?.tapID, 77)
        XCTAssertEqual(recordingService.startCalls.first?.aggregateDeviceID, 88)
        XCTAssertEqual(recordingService.startCalls.first?.capturedAppName, "Zoom")
    }

    func testStartRecordingFallsBackToMicOnlyWhenTapCreationFails() async {
        let selectedMic = AudioInputDevice(id: 1, uid: "mic-1", name: "Mic")
        let selectedApp = CapturedApp(bundleID: "com.test.zoom", name: "Zoom", pid: 333, icon: nil)
        audioDeviceService.availableDevices = [selectedMic]
        audioDeviceService.selectedDevice = selectedMic
        appAudioService.runningApps = [selectedApp]
        appAudioService.selectedApp = selectedApp
        aggregateDeviceBuilder.tapError = AggregateDeviceBuilderError.failedToCreateTap(-1)

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            appAudioPermissionService: appAudioPermissionService,
            aggregateDeviceBuilder: aggregateDeviceBuilder
        )

        await viewModel.startRecording()

        XCTAssertNil(recordingService.startCalls.first?.tapID)
        XCTAssertNil(recordingService.startCalls.first?.aggregateDeviceID)
        XCTAssertEqual(viewModel.errorMessage, "App audio capture unavailable. Enable Scriberman in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch app. Falling back to microphone-only recording.")
    }

    func testStartRecordingFallsBackToMicOnlyWhenAppStartAttemptFails() async {
        let selectedMic = AudioInputDevice(id: 1, uid: "mic-1", name: "Mic")
        let selectedApp = CapturedApp(bundleID: "com.test.zoom", name: "Zoom", pid: 333, icon: nil)
        audioDeviceService.availableDevices = [selectedMic]
        audioDeviceService.selectedDevice = selectedMic
        appAudioService.runningApps = [selectedApp]
        appAudioService.selectedApp = selectedApp
        aggregateDeviceBuilder.tapResult = 77
        aggregateDeviceBuilder.aggregateResult = 88
        recordingService.startThrowSequence = [MockStartError.failed]

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            appAudioPermissionService: appAudioPermissionService,
            aggregateDeviceBuilder: aggregateDeviceBuilder
        )

        await viewModel.startRecording()

        XCTAssertEqual(recordingService.startCalls.count, 2)
        XCTAssertEqual(recordingService.startCalls.first?.tapID, 77)
        XCTAssertNil(recordingService.startCalls.last?.tapID)
        XCTAssertNil(recordingService.startCalls.last?.aggregateDeviceID)
        XCTAssertEqual(aggregateDeviceBuilder.teardownCalls.count, 1)
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
            appAudioPermissionService: appAudioPermissionService,
            aggregateDeviceBuilder: aggregateDeviceBuilder
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
            appAudioPermissionService: appAudioPermissionService,
            aggregateDeviceBuilder: aggregateDeviceBuilder
        )

        await viewModel.startRecording()

        XCTAssertEqual(appAudioService.refreshCalls, 1)
        XCTAssertEqual(aggregateDeviceBuilder.createTapPIDs, [])
        XCTAssertNil(recordingService.startCalls.first?.tapID)
        XCTAssertNil(recordingService.startCalls.first?.aggregateDeviceID)
        XCTAssertNil(recordingService.startCalls.first?.capturedAppName)
    }

    func testStartRecordingRequestsAppAudioPermissionAndFallsBackWhenDenied() async {
        let selectedMic = AudioInputDevice(id: 1, uid: "mic-1", name: "Mic")
        let selectedApp = CapturedApp(bundleID: "com.test.zoom", name: "Zoom", pid: 333, icon: nil)
        audioDeviceService.availableDevices = [selectedMic]
        audioDeviceService.selectedDevice = selectedMic
        appAudioService.runningApps = [selectedApp]
        appAudioService.selectedApp = selectedApp
        appAudioPermissionService.hasAccess = false
        appAudioPermissionService.requestResult = false

        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            appAudioPermissionService: appAudioPermissionService,
            aggregateDeviceBuilder: aggregateDeviceBuilder
        )

        await viewModel.startRecording()

        XCTAssertEqual(appAudioPermissionService.requestCalls, 1)
        XCTAssertEqual(aggregateDeviceBuilder.createTapPIDs, [])
        XCTAssertNil(recordingService.startCalls.first?.tapID)
        XCTAssertNil(recordingService.startCalls.first?.aggregateDeviceID)
        XCTAssertEqual(viewModel.errorMessage, "App audio capture permission denied. Enable Scriberman in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch app. Falling back to microphone-only recording.")
    }

    func testRecordingMonitorSurfacesPendingInterruptionError() async {
        recordingService.isRecordingOverride = false
        recordingService.pendingError = .captureInterrupted

        await viewModel.startRecording()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(viewModel.errorMessage, RecordingError.captureInterrupted.localizedDescription)
    }

    private func makeSession(status: RecordingStatus) -> RecordingSession {
        RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 12,
            audioURL: "/tmp/audio.wav",
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
private final class MockAppAudioPermissionService: AppAudioPermissionProviding {
    var hasAccess = true
    var requestResult = false
    var requestCalls = 0

    func hasSystemAudioCaptureAccess() -> Bool {
        hasAccess
    }

    func requestSystemAudioCaptureAccess() -> Bool {
        requestCalls += 1
        hasAccess = requestResult
        return requestResult
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

private final class MockAggregateDeviceBuilder: AggregateDeviceBuilding {
    var tapResult: AudioObjectID = 0
    var aggregateResult: AudioDeviceID = 0
    var tapError: Error?
    var aggregateError: Error?

    var createTapPIDs: [pid_t] = []
    var createAggregateInputs: [(micUID: String, tapID: AudioObjectID)] = []
    var destroyedTapIDs: [AudioObjectID] = []
    var teardownCalls: [(tapID: AudioObjectID, aggregateDeviceID: AudioDeviceID)] = []

    func createTap(for pid: pid_t) throws -> AudioObjectID {
        createTapPIDs.append(pid)
        if let tapError {
            throw tapError
        }
        return tapResult
    }

    func createAggregateDevice(micUID: String, tapID: AudioObjectID) throws -> AudioDeviceID {
        createAggregateInputs.append((micUID: micUID, tapID: tapID))
        if let aggregateError {
            throw aggregateError
        }
        return aggregateResult
    }

    func teardown(tapID: AudioObjectID, aggregateDeviceID: AudioDeviceID) {
        teardownCalls.append((tapID: tapID, aggregateDeviceID: aggregateDeviceID))
    }

    func destroyTap(_ tapID: AudioObjectID) {
        destroyedTapIDs.append(tapID)
    }
}
