import SwiftData
import XCTest
@testable import Scriberman

@MainActor
final class JobsViewModelTests: XCTestCase {
    private var workspaceService: MockWorkspaceService!
    private var transcriptionService: MockTranscriptionService!
    private var retranscriptionService: RetranscriptionService!
    private var audioImportService: AudioImportService!
    private var viewModel: JobsViewModel!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspaceService = MockWorkspaceService()
        transcriptionService = MockTranscriptionService()
        retranscriptionService = RetranscriptionService(
            transcriptionService: TranscriptionService(),
            extractSamples: { _, _ in (mic: [0.1], app: nil) },
            prepareModelsHandler: { _ in },
            transcribePassFromSamplesHandler: { _, _, _ in [] }
        )
        audioImportService = AudioImportService(
            retranscriptionService: retranscriptionService,
            probeAudio: { url in
                AudioImportProbeResult(
                    title: url.deletingPathExtension().lastPathComponent,
                    originalFileName: url.lastPathComponent,
                    originalFormat: url.pathExtension.lowercased(),
                    duration: 0
                )
            },
            readChannelSamples: { _ in [[0.1]] },
            writeMonoAAC: { _, _ in },
            retranscribe: { _, _, _ in }
        )

        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)

        viewModel = JobsViewModel(
            workspaceService: workspaceService,
            transcriptionService: transcriptionService,
            retranscriptionService: retranscriptionService,
            audioImportService: audioImportService
        )
    }

    override func tearDown() {
        viewModel = nil
        context = nil
        container = nil
        transcriptionService = nil
        workspaceService = nil
        retranscriptionService = nil
        audioImportService = nil
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

    func testGroupedSectionsOrdersExpectedBucketsAndOmitsEmpty() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = makeDate(year: 2026, month: 3, day: 28, hour: 12)

        let todaySession = makeSession(
            createdAt: makeDate(year: 2026, month: 3, day: 28, hour: 9),
            status: .done
        )
        let yesterdaySession = makeSession(
            createdAt: makeDate(year: 2026, month: 3, day: 27, hour: 15),
            status: .done
        )
        let thisWeekSession = makeSession(
            createdAt: makeDate(year: 2026, month: 3, day: 24, hour: 8),
            status: .done
        )
        let earlierSession = makeSession(
            createdAt: makeDate(year: 2026, month: 3, day: 17, hour: 8),
            status: .done
        )

        let items: [JobsViewModel.SessionListItem] = [
            .recording(todaySession),
            .recording(yesterdaySession),
            .recording(thisWeekSession),
            .recording(earlierSession)
        ]

        let sections = viewModel.groupedSections(for: items, referenceDate: referenceDate, calendar: calendar)

        XCTAssertEqual(sections.map(\.group), [.today, .yesterday, .thisWeek, .earlier])
        XCTAssertEqual(sections[0].items.count, 1)
        XCTAssertEqual(sections[1].items.count, 1)
        XCTAssertEqual(sections[2].items.count, 1)
        XCTAssertEqual(sections[3].items.count, 1)
    }

    func testGroupedSectionsExcludesPendingItems() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = makeDate(year: 2026, month: 3, day: 28, hour: 12)
        let todaySession = makeSession(
            createdAt: makeDate(year: 2026, month: 3, day: 28, hour: 9),
            status: .done
        )
        let pending = PendingSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
            title: "Pending Session",
            createdAt: referenceDate
        )

        let items: [JobsViewModel.SessionListItem] = [
            .pending(pending),
            .recording(todaySession)
        ]

        let sections = viewModel.groupedSections(for: items, referenceDate: referenceDate, calendar: calendar)

        XCTAssertEqual(sections.map(\.group), [.today])
        XCTAssertEqual(sections.first?.items.count, 1)
        guard let firstItem = sections.first?.items.first else {
            return XCTFail("Expected at least one grouped item")
        }
        if case .pending = firstItem {
            XCTFail("Pending item should not be included in grouped sections")
        }
    }

    func testRelativeTimestampFormattingForNowMinutesAndHours() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = makeDate(year: 2026, month: 3, day: 28, hour: 12)

        XCTAssertEqual(
            JobsViewModel.relativeTimestampText(
                for: referenceDate.addingTimeInterval(-30),
                referenceDate: referenceDate,
                calendar: calendar
            ),
            "Now"
        )

        XCTAssertEqual(
            JobsViewModel.relativeTimestampText(
                for: referenceDate.addingTimeInterval(-(2 * 60)),
                referenceDate: referenceDate,
                calendar: calendar
            ),
            "2m ago"
        )

        XCTAssertEqual(
            JobsViewModel.relativeTimestampText(
                for: referenceDate.addingTimeInterval(-(3 * 3600)),
                referenceDate: referenceDate,
                calendar: calendar
            ),
            "3h ago"
        )
    }

    func testShouldDiscardPendingSessionOnSelectionChangeIdleOnly() {
        let pending = PendingSession(title: "Pending")
        let recording = makeSession(status: .done)
        let nonPendingSelection = JobsViewModel.SessionListItem.recording(recording)

        let shouldDiscardIdle = viewModel.shouldDiscardPendingSessionOnSelectionChange(
            pendingSession: pending,
            newSelection: nonPendingSelection,
            isNewSessionIdle: true
        )
        let shouldDiscardRecording = viewModel.shouldDiscardPendingSessionOnSelectionChange(
            pendingSession: pending,
            newSelection: nonPendingSelection,
            isNewSessionIdle: false
        )
        let shouldDiscardWhenPendingSelected = viewModel.shouldDiscardPendingSessionOnSelectionChange(
            pendingSession: pending,
            newSelection: .pending(pending),
            isNewSessionIdle: true
        )

        XCTAssertTrue(shouldDiscardIdle)
        XCTAssertFalse(shouldDiscardRecording)
        XCTAssertFalse(shouldDiscardWhenPendingSelected)
    }

    private func makeSession(
        createdAt: Date = Date(timeIntervalSince1970: 0),
        status: RecordingStatus
    ) -> RecordingSession {
        RecordingSession(
            createdAt: createdAt,
            duration: 8,
            micAudioURL: "/tmp/audio.wav",
            mixdownURL: nil,
            title: "Session",
            status: status
        )
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return calendar.date(from: components) ?? .now
    }
}
