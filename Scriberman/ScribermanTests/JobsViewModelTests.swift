import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
final class JobsViewModelTests {
    private let workspaceService: MockWorkspaceService
    private let transcriptionService: MockTranscriptionService
    private let retranscriptionService: RetranscriptionService
    private let audioImportService: AudioImportService
    private let viewModel: JobsViewModel
    private let container: ModelContainer
    private let context: ModelContext

    init() throws {
        workspaceService = MockWorkspaceService()
        transcriptionService = MockTranscriptionService()
        retranscriptionService = RetranscriptionService(
            transcriptionService: TranscriptionService(),
            extractSamples: { _, _ in (mic: [0.1], app: nil) },
            prepareModelsHandler: { _ in },
            transcribePassFromSamplesHandler: { _, _, _, _, _ in ([], [:]) }
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
            retranscribe: { _, _, _, _ in }
        )

        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
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

    @Test
    func testRetryResetsErrorStatusToRecorded() throws {
        let session = makeSession(status: RecordingStatus.error("boom"))
        context.insert(session)
        try context.save()

        viewModel.retry(session: session, context: context)

        #expect(session.status == .recorded)
        #expect(session.errorMessage == nil)
    }

    @Test
    func testTranscribeSkipsNonRecordedSessions() async throws {
        let session = makeSession(status: RecordingStatus.done)
        context.insert(session)
        try context.save()

        viewModel.transcribe(session: session, context: context)

        // Give asynchronous work chance to start if it was incorrectly queued.
        try await Task.sleep(for: .milliseconds(100))

        #expect(session.status == .done)
        #expect(session.errorMessage == nil)
    }

    @Test
    func testGroupedSectionsOrdersExpectedBucketsAndOmitsEmpty() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = makeDate(year: 2026, month: 3, day: 28, hour: 12)

        let todaySession = makeSession(
            createdAt: makeDate(year: 2026, month: 3, day: 28, hour: 9),
            status: RecordingStatus.done
        )
        let yesterdaySession = makeSession(
            createdAt: makeDate(year: 2026, month: 3, day: 27, hour: 15),
            status: RecordingStatus.done
        )
        let thisWeekSession = makeSession(
            createdAt: makeDate(year: 2026, month: 3, day: 24, hour: 8),
            status: RecordingStatus.done
        )
        let earlierSession = makeSession(
            createdAt: makeDate(year: 2026, month: 3, day: 17, hour: 8),
            status: RecordingStatus.done
        )

        let items: [JobsViewModel.SessionListItem] = [
            .recording(todaySession),
            .recording(yesterdaySession),
            .recording(thisWeekSession),
            .recording(earlierSession)
        ]

        let sections = viewModel.groupedSections(for: items, referenceDate: referenceDate, calendar: calendar)

        #expect(
            sections.map { $0.group }
                == [
                    JobsViewModel.SessionDateGroup.today,
                    JobsViewModel.SessionDateGroup.yesterday,
                    JobsViewModel.SessionDateGroup.thisWeek,
                    JobsViewModel.SessionDateGroup.earlier
                ]
        )
        #expect(sections[0].items.count == 1)
        #expect(sections[1].items.count == 1)
        #expect(sections[2].items.count == 1)
        #expect(sections[3].items.count == 1)
    }

    @Test
    func testGroupedSectionsExcludesPendingItems() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = makeDate(year: 2026, month: 3, day: 28, hour: 12)
        let todaySession = makeSession(
            createdAt: makeDate(year: 2026, month: 3, day: 28, hour: 9),
            status: RecordingStatus.done
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

        #expect(sections.map { $0.group } == [JobsViewModel.SessionDateGroup.today])
        #expect(sections.first?.items.count == 1)
        guard let firstItem = sections.first?.items.first else {
            Issue.record("Expected at least one grouped item")
            return
        }
        if case .pending = firstItem {
            Issue.record("Pending item should not be included in grouped sections")
        }
    }

    @Test
    func testRelativeTimestampFormattingForNowMinutesAndHours() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = makeDate(year: 2026, month: 3, day: 28, hour: 12)

        #expect(
            JobsViewModel.relativeTimestampText(
                for: referenceDate.addingTimeInterval(-30),
                referenceDate: referenceDate,
                calendar: calendar
            ) == "Now"
        )

        #expect(
            JobsViewModel.relativeTimestampText(
                for: referenceDate.addingTimeInterval(-(2 * 60)),
                referenceDate: referenceDate,
                calendar: calendar
            ) == "2m ago"
        )

        #expect(
            JobsViewModel.relativeTimestampText(
                for: referenceDate.addingTimeInterval(-(3 * 3600)),
                referenceDate: referenceDate,
                calendar: calendar
            ) == "3h ago"
        )
    }

    @Test
    func testShouldDiscardPendingSessionOnSelectionChangeIdleOnly() {
        let pending = PendingSession(title: "Pending")
        let recording = makeSession(status: RecordingStatus.done)
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

        #expect(shouldDiscardIdle)
        #expect(!(shouldDiscardRecording))
        #expect(!(shouldDiscardWhenPendingSelected))
    }

    @Test
    func testSessionItemsReturnsEmptyForEmptyInputs() {
        let items = viewModel.sessionItems(
            recordingSessions: [],
            importedSessions: [],
            preserving: nil
        )

        #expect(items.isEmpty)
    }

    @Test
    func testSessionItemsMergesRecordingAndImportedSessionsSortedDescending() {
        let oldestRecording = makeSession(createdAt: makeDate(year: 2026, month: 3, day: 20, hour: 8), status: RecordingStatus.done)
        let newestImported = makeImportedSession(createdAt: makeDate(year: 2026, month: 3, day: 22, hour: 9))
        let middleRecording = makeSession(createdAt: makeDate(year: 2026, month: 3, day: 21, hour: 10), status: RecordingStatus.done)

        let items = viewModel.sessionItems(
            recordingSessions: [oldestRecording, middleRecording],
            importedSessions: [newestImported],
            preserving: nil
        )

        #expect(items.count == 3)
        #expect(items.map { $0.id } == [
            JobsViewModel.SessionListItem.imported(newestImported).id,
            JobsViewModel.SessionListItem.recording(middleRecording).id,
            JobsViewModel.SessionListItem.recording(oldestRecording).id
        ])
    }

    @Test
    func testSessionItemsPreservesSelectedRecordingWhenMissingFromRefreshedQuery() {
        let selectedRecording = makeSession(createdAt: makeDate(year: 2026, month: 3, day: 21, hour: 12), status: RecordingStatus.done)
        let refreshedRecording = makeSession(createdAt: makeDate(year: 2026, month: 3, day: 21, hour: 10), status: RecordingStatus.done)

        let items = viewModel.sessionItems(
            recordingSessions: [refreshedRecording],
            importedSessions: [],
            preserving: .recording(selectedRecording)
        )

        #expect(items.count == 2)
        #expect(items.contains(where: { $0.id == JobsViewModel.SessionListItem.recording(selectedRecording).id }))
    }

    @Test
    func testSessionItemsDoesNotPreserveNonRecordingSelections() {
        let selectedImported = makeImportedSession(createdAt: makeDate(year: 2026, month: 3, day: 21, hour: 12))
        let refreshedRecording = makeSession(createdAt: makeDate(year: 2026, month: 3, day: 21, hour: 10), status: RecordingStatus.done)

        let items = viewModel.sessionItems(
            recordingSessions: [refreshedRecording],
            importedSessions: [],
            preserving: .imported(selectedImported)
        )

        #expect(items.count == 1)
        #expect(items.first?.id == JobsViewModel.SessionListItem.recording(refreshedRecording).id)
    }

    @Test
    func testExportTranscriptWritesMarkdownWhenDestinationSelected() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let exportViewModel = JobsViewModel(
            workspaceService: workspaceService,
            transcriptionService: transcriptionService,
            retranscriptionService: retranscriptionService,
            audioImportService: audioImportService,
            transcriptExportService: TranscriptExportService(),
            savePanelPresenter: { _ in outputURL }
        )

        let session = makeSession(status: RecordingStatus.done)
        session.transcript = makeTranscript()

        try await exportViewModel.exportTranscript(for: session)

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(content.hasPrefix("# Session"))
        #expect(content.contains("**Speaker 1** [00:00 – 00:02]"))
    }

    @Test
    func testExportTranscriptReturnsWithoutWritingWhenSavePanelCancelled() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let exportViewModel = JobsViewModel(
            workspaceService: workspaceService,
            transcriptionService: transcriptionService,
            retranscriptionService: retranscriptionService,
            audioImportService: audioImportService,
            transcriptExportService: TranscriptExportService(),
            savePanelPresenter: { _ in nil }
        )

        let session = makeSession(status: RecordingStatus.done)
        session.transcript = makeTranscript()

        try await exportViewModel.exportTranscript(for: session)

        #expect(!(FileManager.default.fileExists(atPath: outputURL.path)))
    }

    @Test
    func testExportTranscriptThrowsWhenTranscriptUnavailable() async {
        let exportViewModel = JobsViewModel(
            workspaceService: workspaceService,
            transcriptionService: transcriptionService,
            retranscriptionService: retranscriptionService,
            audioImportService: audioImportService,
            transcriptExportService: TranscriptExportService(),
            savePanelPresenter: { _ in nil }
        )

        let session = makeSession(status: RecordingStatus.done)

        do {
            try await exportViewModel.exportTranscript(for: session)
            Issue.record("Expected transcriptUnavailable error")
        } catch let error as TranscriptExportError {
            #expect(error == .transcriptUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
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

    private func makeImportedSession(
        createdAt: Date = Date(timeIntervalSince1970: 0),
        status: RecordingStatus = .done
    ) -> ImportedSession {
        ImportedSession(
            createdAt: createdAt,
            duration: 8,
            mixdownURL: "/tmp/imported.m4a",
            title: "Imported Session",
            originalFileName: "imported.m4a",
            originalFormat: "m4a",
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

    private func makeTranscript() -> Transcript {
        Transcript(
            fullText: "hello there",
            segments: [
                TranscriptSegment(speakerId: "S1", text: "hello", startTime: 0, endTime: 2),
                TranscriptSegment(speakerId: "S2", text: "there", startTime: 3, endTime: 5)
            ],
            speakers: [
                TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#4F46E5"),
                TranscriptSpeaker(id: "S2", label: "Speaker 2", colorHex: "#16A34A")
            ]
        )
    }
}
