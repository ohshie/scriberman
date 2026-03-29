import Combine
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

    func testStateMachineTransitionsIdleToRecordingToStopped() async {
        recordingService.isRecordingOverride = false
        recordingService.audioLevelOverride = 0
        let stoppedSession = RecordingSession(
            createdAt: .now,
            duration: 3,
            micAudioURL: "/tmp/test.wav",
            title: "Recorded",
            status: .recorded
        )
        recordingService.stopReturns = stoppedSession

        await viewModel.startRecording(title: "Session", context: context)
        guard case .recording = viewModel.state else {
            return XCTFail("Expected recording state after start")
        }

        await viewModel.stopRecording(context: context)
        guard case let .stopped(session) = viewModel.state else {
            return XCTFail("Expected stopped state after stop")
        }
        XCTAssertEqual(session.id, stoppedSession.id)
    }

    func testResetReturnsIdleFromStoppedState() {
        let stoppedSession = RecordingSession(
            createdAt: .now,
            duration: 3,
            micAudioURL: "/tmp/test.wav",
            title: "Recorded",
            status: .recorded
        )
        viewModel.state = .stopped(session: stoppedSession)

        viewModel.reset()

        guard case .idle = viewModel.state else {
            return XCTFail("Expected idle state after reset")
        }
    }
}

@MainActor
private final class MockNewSessionAppAudioService: AppAudioServiceProtocol {
    @Published var runningApps: [CapturedApp] = []
    @Published var selectedApp: CapturedApp?
    var refreshCalls = 0

    var runningAppsPublisher: AnyPublisher<[CapturedApp], Never> {
        $runningApps.eraseToAnyPublisher()
    }

    var selectedAppPublisher: AnyPublisher<CapturedApp?, Never> {
        $selectedApp.eraseToAnyPublisher()
    }

    func refreshRunningApps() {
        refreshCalls += 1
    }
}
