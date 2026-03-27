import XCTest
@testable import Scriberman

@MainActor
final class StudioViewModelTests: XCTestCase {
    private var workspaceService: MockWorkspaceService!
    private var recordingService: MockRecordingService!
    private var viewModel: StudioViewModel!
    private var workspace: Workspace!

    override func setUp() {
        super.setUp()
        workspaceService = MockWorkspaceService()
        recordingService = MockRecordingService()
        workspace = Workspace(rootURL: URL(fileURLWithPath: "/tmp/workspace"))
        workspaceService.requireWritableResult = .success(workspace)
        viewModel = StudioViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService
        )
    }

    override func tearDown() {
        viewModel = nil
        workspace = nil
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
