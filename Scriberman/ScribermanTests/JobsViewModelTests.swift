import SwiftData
import XCTest
@testable import Scriberman

@MainActor
final class JobsViewModelTests: XCTestCase {
    private var workspaceService: MockWorkspaceService!
    private var transcriptionService: MockTranscriptionService!
    private var viewModel: JobsViewModel!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspaceService = MockWorkspaceService()
        transcriptionService = MockTranscriptionService()

        container = try ModelContainer(
            for: RecordingSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)

        viewModel = JobsViewModel(
            workspaceService: workspaceService,
            transcriptionService: transcriptionService
        )
    }

    override func tearDown() {
        viewModel = nil
        context = nil
        container = nil
        transcriptionService = nil
        workspaceService = nil
        super.tearDown()
    }

    func testRetryResetsErrorStatusToRecorded() throws {
        let session = makeSession(status: .error("boom"))
        context.insert(session)
        try context.save()

        viewModel.retry(session: session, context: context)

        XCTAssertEqual(session.status, .recorded)
        XCTAssertNil(session.errorMessage)
    }

    func testTranscribeSkipsNonRecordedSessions() throws {
        let session = makeSession(status: .done)
        context.insert(session)
        try context.save()

        viewModel.transcribe(session: session, context: context)

        // Give asynchronous work chance to start if it was incorrectly queued.
        let expectation = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(session.status, .done)
        XCTAssertNil(session.errorMessage)
    }

    private func makeSession(status: RecordingStatus) -> RecordingSession {
        RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 8,
            micAudioURL: "/tmp/audio.wav",
            title: "Session",
            status: status
        )
    }
}
