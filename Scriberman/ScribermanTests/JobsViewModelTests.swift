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

    // MARK: - Deletion

    /// A workspace rooted in a fresh temporary directory, with the two areas sessions live in.
    private func makeTemporaryWorkspace() throws -> Workspace {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = Workspace(rootURL: root)
        try FileManager.default.createDirectory(at: workspace.recordingsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.importsURL, withIntermediateDirectories: true)
        return workspace
    }

    /// A session folder holding everything a real recording leaves behind.
    @discardableResult
    private func makePopulatedSessionFolder(in parent: URL, named name: String) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["mic.wav", "app.wav", "recording.m4a", "mic.wav.timing", "app.wav.timing", "screen.mov"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(file))
        }
        return folder
    }

    // MARK: Containment guard

    @Test
    func testAFolderInsideTheRecordingsAreaIsRemovable() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let folder = workspace.recordingsURL.appendingPathComponent("Recording Jan 01 at 10-00 ab")
        #expect(JobsViewModel.isRemovableSessionFolder(folder, in: workspace))
    }

    @Test
    func testAFolderInsideTheImportsAreaIsRemovable() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let folder = workspace.importsURL.appendingPathComponent("some-import")
        #expect(JobsViewModel.isRemovableSessionFolder(folder, in: workspace))
    }

    /// The area roots are not session folders. Removing `recordings/` would take every session.
    @Test
    func testTheAreaRootsThemselvesAreNotRemovable() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        #expect(!JobsViewModel.isRemovableSessionFolder(workspace.recordingsURL, in: workspace))
        #expect(!JobsViewModel.isRemovableSessionFolder(workspace.importsURL, in: workspace))
        #expect(!JobsViewModel.isRemovableSessionFolder(workspace.rootURL, in: workspace))
    }

    @Test
    func testAFolderOutsideTheWorkspaceIsNotRemovable() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        #expect(!JobsViewModel.isRemovableSessionFolder(URL(fileURLWithPath: "/"), in: workspace))
        #expect(!JobsViewModel.isRemovableSessionFolder(
            URL(fileURLWithPath: NSHomeDirectory()), in: workspace
        ))
    }

    /// The reason the check resolves paths rather than comparing strings: a prefix can match
    /// textually while pointing somewhere else entirely.
    @Test
    func testAPathEscapingWithDotDotIsNotRemovable() throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let escaping = workspace.recordingsURL
            .appendingPathComponent("..")
            .appendingPathComponent("..")
            .appendingPathComponent("somewhere-else")
        #expect(!JobsViewModel.isRemovableSessionFolder(escaping, in: workspace))
    }

    // MARK: Recording deletion

    @Test
    func testDeletingARecordingRemovesItsWholeFolder() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        workspaceService.currentWorkspaceResult = workspace
        let folder = try makePopulatedSessionFolder(in: workspace.recordingsURL, named: "Recording A")

        let session = RecordingSession(
            duration: 60,
            micAudioURL: folder.appendingPathComponent("mic.wav").path,
            title: "A"
        )
        context.insert(session)
        try context.save()

        await viewModel.delete(session: session, context: context)

        // The folder goes, not just mic.wav — app audio, the mixdown, both sidecars and the screen
        // recording used to survive a delete forever.
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try context.fetch(FetchDescriptor<RecordingSession>()).isEmpty)
    }

    @Test
    func testDeletingARecordingWithNoFilesLeftStillRemovesTheRecord() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        workspaceService.currentWorkspaceResult = workspace

        let session = RecordingSession(
            duration: 60,
            micAudioURL: workspace.recordingsURL
                .appendingPathComponent("Gone").appendingPathComponent("mic.wav").path,
            title: "Gone"
        )
        context.insert(session)
        try context.save()

        await viewModel.delete(session: session, context: context)

        #expect(try context.fetch(FetchDescriptor<RecordingSession>()).isEmpty)
    }

    /// A refusal must not make the session undeletable — the row goes, the directory stays.
    @Test
    func testARecordingPointingOutsideTheWorkspaceKeepsItsFolderButLosesItsRecord() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        workspaceService.currentWorkspaceResult = workspace

        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appendingPathComponent("mic.wav"))

        let session = RecordingSession(
            duration: 60,
            micAudioURL: outside.appendingPathComponent("mic.wav").path,
            title: "Outside"
        )
        context.insert(session)
        try context.save()

        await viewModel.delete(session: session, context: context)

        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try context.fetch(FetchDescriptor<RecordingSession>()).isEmpty)
    }

    // MARK: Imported deletion

    @Test
    func testDeletingAnImportedSessionRemovesItsFolderEvenWithOtherFilesInIt() async throws {
        let workspace = try makeTemporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        workspaceService.currentWorkspaceResult = workspace
        let folder = try makePopulatedSessionFolder(in: workspace.importsURL, named: "Imported A")

        let session = makeImportedSession(createdAt: makeDate(year: 2026, month: 3, day: 20, hour: 8))
        session.mixdownURL = folder.appendingPathComponent("recording.m4a").path
        context.insert(session)
        try context.save()

        await viewModel.deleteImported(session: session, context: context)

        // Previously the folder survived unless it happened to be empty afterwards.
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try context.fetch(FetchDescriptor<ImportedSession>()).isEmpty)
    }

    // MARK: - Tag filtering

    private func tagged(_ session: RecordingSession, _ tags: [RecordingTag]) -> RecordingSession {
        session.tags = tags
        return session
    }

    @Test
    func testNoSelectedTagsLeavesTheListUnfiltered() {
        let recording = makeSession(createdAt: makeDate(year: 2026, month: 3, day: 20, hour: 8), status: RecordingStatus.done)
        let imported = makeImportedSession(createdAt: makeDate(year: 2026, month: 3, day: 21, hour: 9))

        let items = viewModel.sessionItems(
            recordingSessions: [recording],
            importedSessions: [imported],
            preserving: nil
        )

        #expect(items.count == 2)
    }

    @Test
    func testOneSelectedTagFiltersToRecordingsCarryingIt() {
        let work = RecordingTag(name: "Work", colorHex: "112233")
        let client = RecordingTag(name: "Client", colorHex: "445566")
        let carries = tagged(
            makeSession(createdAt: makeDate(year: 2026, month: 3, day: 20, hour: 8), status: RecordingStatus.done),
            [work]
        )
        let doesNot = tagged(
            makeSession(createdAt: makeDate(year: 2026, month: 3, day: 21, hour: 8), status: RecordingStatus.done),
            [client]
        )

        viewModel.selectedTagIDs = [work.id]
        let items = viewModel.sessionItems(
            recordingSessions: [carries, doesNot],
            importedSessions: [],
            preserving: nil
        )

        #expect(items.count == 1)
        #expect(items.first?.id == "recording:\(carries.id.uuidString)")
    }

    /// Union, not intersection: a recording carrying either selected tag matches, and one carrying
    /// both appears once.
    @Test
    func testTwoSelectedTagsMatchEitherWithoutDuplicating() {
        let work = RecordingTag(name: "Work", colorHex: "112233")
        let client = RecordingTag(name: "Client", colorHex: "445566")
        let other = RecordingTag(name: "Other", colorHex: "778899")
        let onlyWork = tagged(makeSession(createdAt: makeDate(year: 2026, month: 3, day: 20, hour: 8), status: RecordingStatus.done), [work])
        let both = tagged(makeSession(createdAt: makeDate(year: 2026, month: 3, day: 21, hour: 8), status: RecordingStatus.done), [work, client])
        let neither = tagged(makeSession(createdAt: makeDate(year: 2026, month: 3, day: 22, hour: 8), status: RecordingStatus.done), [other])

        viewModel.selectedTagIDs = [work.id, client.id]
        let items = viewModel.sessionItems(
            recordingSessions: [onlyWork, both, neither],
            importedSessions: [],
            preserving: nil
        )

        #expect(items.count == 2)
        #expect(!items.contains { $0.id == "recording:\(neither.id.uuidString)" })
    }

    /// The default tag is never alongside another, so its chip finds exactly the recordings the
    /// user has not tagged.
    @Test
    func testTheDefaultTagsChipFindsUntaggedRecordings() {
        let defaultTag = RecordingTag(name: "recording", colorHex: "0A84FF", isDefault: true)
        let work = RecordingTag(name: "Work", colorHex: "112233")
        let untagged = tagged(makeSession(createdAt: makeDate(year: 2026, month: 3, day: 20, hour: 8), status: RecordingStatus.done), [defaultTag])
        let userTagged = tagged(makeSession(createdAt: makeDate(year: 2026, month: 3, day: 21, hour: 8), status: RecordingStatus.done), [work])

        viewModel.selectedTagIDs = [defaultTag.id]
        let items = viewModel.sessionItems(
            recordingSessions: [untagged, userTagged],
            importedSessions: [],
            preserving: nil
        )

        #expect(items.count == 1)
        #expect(items.first?.id == "recording:\(untagged.id.uuidString)")
    }

    /// Imported and pending sessions carry no tags, so a filtered list cannot contain them.
    @Test
    func testFilteringHidesSessionsThatCarryNoTags() {
        let work = RecordingTag(name: "Work", colorHex: "112233")
        let recording = tagged(makeSession(createdAt: makeDate(year: 2026, month: 3, day: 20, hour: 8), status: RecordingStatus.done), [work])
        let imported = makeImportedSession(createdAt: makeDate(year: 2026, month: 3, day: 21, hour: 9))

        viewModel.selectedTagIDs = [work.id]
        let items = viewModel.sessionItems(
            recordingSessions: [recording],
            importedSessions: [imported],
            preserving: nil
        )

        #expect(items.count == 1)
        #expect(!items.contains { if case .imported = $0 { return true } else { return false } })
    }

    /// Filtering wins over keeping the selected row visible: an explicit filter should not be
    /// silently overridden.
    @Test
    func testFilteringRemovesASelectedRecordingThatDoesNotMatch() {
        let work = RecordingTag(name: "Work", colorHex: "112233")
        let other = RecordingTag(name: "Other", colorHex: "445566")
        let selected = tagged(makeSession(createdAt: makeDate(year: 2026, month: 3, day: 20, hour: 8), status: RecordingStatus.done), [other])
        // Another recording carries "Work", so it is a tag with a chip. Filtering by a tag nothing
        // carries is ignored instead, which is covered separately.
        let matching = tagged(makeSession(createdAt: makeDate(year: 2026, month: 3, day: 21, hour: 8), status: RecordingStatus.done), [work])

        viewModel.selectedTagIDs = [work.id]
        let items = viewModel.sessionItems(
            recordingSessions: [selected, matching],
            importedSessions: [],
            preserving: .recording(selected)
        )

        // The selection-preserving branch does not override an explicit filter.
        #expect(items.count == 1)
        #expect(items.first?.id == "recording:\(matching.id.uuidString)")
    }

    /// A tag no recording carries has no chip, so a selection naming only such tags cannot be
    /// undone through the UI. It is ignored instead, which leaves the list unfiltered.
    @Test
    func testASelectedTagNoRecordingCarriesIsIgnored() {
        let orphan = RecordingTag(name: "Orphan", colorHex: "112233")
        let work = RecordingTag(name: "Work", colorHex: "445566")
        let recording = tagged(
            makeSession(createdAt: makeDate(year: 2026, month: 3, day: 20, hour: 8), status: RecordingStatus.done),
            [work]
        )

        viewModel.selectedTagIDs = [orphan.id]
        let items = viewModel.sessionItems(
            recordingSessions: [recording],
            importedSessions: [],
            preserving: nil
        )

        // Unfiltered rather than empty: an empty list with no matching chip is a dead end.
        #expect(items.count == 1)
    }

    @Test
    func testAStaleSelectionDoesNotSuppressALiveOne() {
        let orphan = RecordingTag(name: "Orphan", colorHex: "112233")
        let work = RecordingTag(name: "Work", colorHex: "445566")
        let other = RecordingTag(name: "Other", colorHex: "778899")
        let carries = tagged(
            makeSession(createdAt: makeDate(year: 2026, month: 3, day: 20, hour: 8), status: RecordingStatus.done),
            [work]
        )
        let doesNot = tagged(
            makeSession(createdAt: makeDate(year: 2026, month: 3, day: 21, hour: 8), status: RecordingStatus.done),
            [other]
        )

        viewModel.selectedTagIDs = [orphan.id, work.id]
        let items = viewModel.sessionItems(
            recordingSessions: [carries, doesNot],
            importedSessions: [],
            preserving: nil
        )

        #expect(items.count == 1)
        #expect(items.first?.id == "recording:\(carries.id.uuidString)")
    }

    @Test
    func testTogglingAChipAddsThenRemovesIt() {
        let id = UUID()
        viewModel.toggleTagFilter(id)
        #expect(viewModel.selectedTagIDs == [id])
        // A second click is the clear; there is no separate clear control.
        viewModel.toggleTagFilter(id)
        #expect(viewModel.selectedTagIDs.isEmpty)
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

    // MARK: - Search

    private func titled(_ session: RecordingSession, _ title: String) -> RecordingSession {
        session.title = title
        return session
    }

    private func spoken(_ session: RecordingSession, _ text: String) -> RecordingSession {
        session.transcript = Transcript(
            fullText: text,
            segments: [TranscriptSegment(speakerId: "A", text: text, startTime: 0, endTime: 1)],
            speakers: []
        )
        return session
    }

    private func makeSearchableSession(
        day: Int,
        title: String,
        spokenText: String? = nil
    ) -> RecordingSession {
        let session = titled(
            makeSession(createdAt: makeDate(year: 2026, month: 3, day: day, hour: 8), status: RecordingStatus.done),
            title
        )
        guard let spokenText else { return session }
        return spoken(session, spokenText)
    }

    @Test
    func testAQueryMatchesASessionTitle() {
        let match = makeSearchableSession(day: 20, title: "Migration planning")
        let other = makeSearchableSession(day: 21, title: "Standup")

        viewModel.searchQuery = "migration"
        let items = viewModel.sessionItems(recordingSessions: [match, other], importedSessions: [], preserving: nil)

        #expect(items.count == 1)
        #expect(items.first?.id == "recording:\(match.id.uuidString)")
    }

    @Test
    func testAQueryMatchesTranscriptTextTheTitleDoesNotContain() {
        let match = makeSearchableSession(day: 20, title: "Standup", spokenText: "we should postpone the migration")
        let other = makeSearchableSession(day: 21, title: "Retro", spokenText: "nothing to report")

        viewModel.searchQuery = "migration"
        let items = viewModel.sessionItems(recordingSessions: [match, other], importedSessions: [], preserving: nil)

        #expect(items.count == 1)
        #expect(items.first?.id == "recording:\(match.id.uuidString)")
    }

    @Test
    func testAnImportedSessionIsSearchableByItsTranscript() {
        let imported = makeImportedSession(createdAt: makeDate(year: 2026, month: 3, day: 20, hour: 8))
        imported.transcript = Transcript(
            fullText: "the conference talk about migration",
            segments: [],
            speakers: []
        )

        viewModel.searchQuery = "migration"
        let items = viewModel.sessionItems(recordingSessions: [], importedSessions: [imported], preserving: nil)

        #expect(items.count == 1)
        #expect(items.first?.id == "imported:\(imported.id.uuidString)")
    }

    /// A session matching on both is still one row, reported as a transcript match — the one a
    /// snippet can be built from.
    @Test
    func testASessionMatchingTitleAndTranscriptAppearsOnce() {
        let both = makeSearchableSession(day: 20, title: "Migration planning", spokenText: "the migration is next week")

        viewModel.searchQuery = "migration"
        let items = viewModel.sessionItems(recordingSessions: [both], importedSessions: [], preserving: nil)

        #expect(items.count == 1)
        #expect(JobsViewModel.matches(query: "migration", item: items[0]) == .transcript)
    }

    @Test
    func testATitleOnlyMatchIsReportedAsATitleMatch() {
        let session = makeSearchableSession(day: 20, title: "Migration planning", spokenText: "nothing relevant")

        #expect(JobsViewModel.matches(query: "migration", item: .recording(session)) == .title)
    }

    @Test
    func testMatchingIgnoresCaseAndDiacritics() {
        let session = makeSearchableSession(day: 20, title: "Standup", spokenText: "the café was closed")

        viewModel.searchQuery = "CAFE"
        let items = viewModel.sessionItems(recordingSessions: [session], importedSessions: [], preserving: nil)

        #expect(items.count == 1)
    }

    @Test
    func testAnEmptyQueryAppliesNoSearch() {
        let first = makeSearchableSession(day: 20, title: "Migration planning")
        let second = makeSearchableSession(day: 21, title: "Standup")

        viewModel.searchQuery = "   "
        let items = viewModel.sessionItems(recordingSessions: [first, second], importedSessions: [], preserving: nil)

        #expect(items.count == 2)
        #expect(viewModel.activeSearchQuery == nil)
    }

    /// The list goes empty rather than falling back to everything: a list that ignored the query
    /// would look like a search that found the whole library.
    @Test
    func testAQueryMatchingNothingProducesAnEmptyList() {
        let first = makeSearchableSession(day: 20, title: "Migration planning")
        let second = makeSearchableSession(day: 21, title: "Standup")

        viewModel.searchQuery = "kubernetes"
        let items = viewModel.sessionItems(recordingSessions: [first, second], importedSessions: [], preserving: nil)

        #expect(items.isEmpty)
    }

    @Test
    func testTagsNarrowAndTheQuerySearchesWithin() {
        let work = RecordingTag(name: "Work", colorHex: "112233")
        let personal = RecordingTag(name: "Personal", colorHex: "445566")
        let taggedAndMatching = tagged(makeSearchableSession(day: 20, title: "Migration planning"), [work])
        let taggedNotMatching = tagged(makeSearchableSession(day: 21, title: "Standup"), [work])
        let matchingWrongTag = tagged(makeSearchableSession(day: 22, title: "Migration retro"), [personal])

        viewModel.selectedTagIDs = [work.id]
        viewModel.searchQuery = "migration"
        let items = viewModel.sessionItems(
            recordingSessions: [taggedAndMatching, taggedNotMatching, matchingWrongTag],
            importedSessions: [],
            preserving: nil
        )

        #expect(items.count == 1)
        #expect(items.first?.id == "recording:\(taggedAndMatching.id.uuidString)")
    }

    /// The same AND from the other direction: a query alone reaches sessions the tag filter would
    /// have excluded, so the filter is genuinely narrowing rather than being ignored.
    @Test
    func testTheQueryAloneReachesSessionsTheTagFilterWouldExclude() {
        let work = RecordingTag(name: "Work", colorHex: "112233")
        let personal = RecordingTag(name: "Personal", colorHex: "445566")
        let workMatch = tagged(makeSearchableSession(day: 20, title: "Migration planning"), [work])
        let personalMatch = tagged(makeSearchableSession(day: 21, title: "Migration retro"), [personal])

        viewModel.searchQuery = "migration"
        let items = viewModel.sessionItems(
            recordingSessions: [workMatch, personalMatch],
            importedSessions: [],
            preserving: nil
        )

        #expect(items.count == 2)
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
