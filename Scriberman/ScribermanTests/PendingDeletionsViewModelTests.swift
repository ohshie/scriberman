import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
final class PendingDeletionsViewModelTests {
    private let workspace: Workspace
    private let workspaceService = MockWorkspaceService()
    private let container: ModelContainer
    private let context: ModelContext
    private let undoManager = UndoManager.forTests()
    private var announcements: [String] = []
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// The clock the coordinator stamps deletes with and the view model counts down from.
    private var now: Date
    private lazy var coordinator = makeCoordinator()
    private lazy var viewModel = makeViewModel(coordinator: coordinator)

    init() throws {
        now = start
        workspace = Self.makeWorkspace()
        try FileManager.default.createDirectory(at: workspace.recordingsURL, withIntermediateDirectories: true)
        workspaceService.currentWorkspaceResult = workspace
        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    deinit {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: HoldingFolder(workspace: workspace).url.path
        )
        try? FileManager.default.removeItem(at: workspace.rootURL)
    }

    private static func makeWorkspace() -> Workspace {
        Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    private func makeCoordinator() -> SessionDeletionCoordinator {
        SessionDeletionCoordinator(
            workspaceService: workspaceService,
            now: { [unowned self] in now },
            announce: { [unowned self] in announcements.append($0) },
            startAccess: { _ in true },
            stopAccess: { _ in }
        )
    }

    private func makeViewModel(coordinator: SessionDeletionCoordinator) -> PendingDeletionsViewModel {
        PendingDeletionsViewModel(coordinator: coordinator, now: { [unowned self] in now })
    }

    // MARK: - Fixtures

    private var holding: HoldingFolder { HoldingFolder(workspace: workspace) }

    private func makeRecording(title: String, duration: TimeInterval = 60, createdAt: Date? = nil) throws -> RecordingSession {
        let folder = workspace.recordingsURL.appendingPathComponent(title, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appendingPathComponent("mic.wav"))
        let session = RecordingSession(
            duration: duration,
            micAudioURL: folder.appendingPathComponent("mic.wav").path,
            title: title,
            status: .done
        )
        if let createdAt {
            session.createdAt = createdAt
        }
        context.insert(session)
        try context.save()
        return session
    }

    /// Deletes a new recording and returns its `id`.
    @discardableResult
    private func deleteRecording(title: String, duration: TimeInterval = 60, createdAt: Date? = nil) async throws -> UUID {
        let session = try makeRecording(title: title, duration: duration, createdAt: createdAt)
        let id = session.id
        let result = await coordinator.delete(session, context: context, undoManager: undoManager)
        #expect(result == .deleted)
        return id
    }

    private func storedRecordingIDs() throws -> [UUID] {
        try ModelContext(container).fetch(FetchDescriptor<RecordingSession>()).map(\.id)
    }

    private func row(_ id: UUID) throws -> PendingDeletionsViewModel.Row {
        try #require(viewModel.rows.first { $0.id == id })
    }

    // MARK: - Rows

    @Test
    func testRowsListHeldSessionsNewestDeleteFirstWithTitleDateAndDuration() async throws {
        let createdAt = start.addingTimeInterval(-3_600)
        let first = try await deleteRecording(title: "First", duration: 90, createdAt: createdAt)
        now = start.addingTimeInterval(60)
        let second = try await deleteRecording(title: "Second", duration: 30)
        now = start.addingTimeInterval(120)
        let third = try await deleteRecording(title: "Third")

        await viewModel.refresh()

        #expect(viewModel.rows.map(\.id) == [third, second, first])
        let row = try row(first)
        #expect(row.title == "First")
        #expect(row.createdAt == createdAt)
        #expect(row.duration == 90)
        #expect(row.deletedAt == start)
    }

    @Test
    func testRowsAreReadFromTheHoldingFolderSoTheyOutliveTheRun() async throws {
        let id = try await deleteRecording(title: "Kept")

        let relaunched = makeViewModel(coordinator: makeCoordinator())
        await relaunched.refresh()

        #expect(relaunched.rows.map(\.id) == [id])
        #expect(relaunched.rows.first?.title == "Kept")
    }

    @Test
    func testOnlyTheActiveWorkspacesHeldSessionsAreListed() async throws {
        try await deleteRecording(title: "Elsewhere")
        workspaceService.currentWorkspaceResult = Self.makeWorkspace()

        await viewModel.refresh()

        #expect(viewModel.rows.isEmpty)
    }

    @Test
    func testAHeldFolderWithoutAReadableSnapshotIsNotListed() async throws {
        let id = try await deleteRecording(title: "Listed")
        let broken = holding.heldFolder(for: UUID())
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: SessionSnapshot.url(in: broken))

        await viewModel.refresh()

        #expect(viewModel.rows.map(\.id) == [id])
    }

    // MARK: - Entry point

    @Test
    func testTheEntryPointIsInactiveWithNothingHeldAndOpeningDoesNothing() async {
        await viewModel.refresh()

        #expect(!viewModel.isEntryEnabled)
        viewModel.open()
        #expect(!viewModel.isOpen)
    }

    @Test
    func testTheEntryPointOpensTheViewOnceSomethingIsHeld() async throws {
        try await deleteRecording(title: "Held")

        await viewModel.refresh()
        viewModel.open()

        #expect(viewModel.isEntryEnabled)
        #expect(viewModel.isOpen)
    }

    @Test
    func testTheCoordinatorReportsAChangeAfterADeleteAndAnUndo() async throws {
        let before = coordinator.holdingChanges.revision
        try await deleteRecording(title: "Changed")
        await coordinator.waitUntilIdle()
        let afterDelete = coordinator.holdingChanges.revision
        #expect(afterDelete != before)

        undoManager.undo()
        await coordinator.waitUntilIdle()

        #expect(coordinator.holdingChanges.revision != afterDelete)
    }

    @Test
    func testTheViewClosesWhenARefreshFindsNothingHeld() async throws {
        try await deleteRecording(title: "Undone elsewhere")
        await viewModel.refresh()
        viewModel.open()

        undoManager.undo()
        await coordinator.waitUntilIdle()
        await viewModel.refresh()

        #expect(!viewModel.isOpen)
        #expect(!viewModel.isEntryEnabled)
    }

    // MARK: - Countdown

    /// Seconds since the delete, and the text the row shows then.
    private nonisolated static let countdownCases: [(TimeInterval, String)] = [
        (0, "Removed in 24 h"),
        (1, "Removed in 23 h"),
        (22 * 3_600 + 1, "Removed in 1 h"),
        (23 * 3_600, "Removed in 1 h"),
        (23 * 3_600 + 1, "Removed in 59 min"),
        (24 * 3_600 - 60, "Removed in 1 min"),
        (24 * 3_600 - 59, "Removed in under 1 min"),
        (24 * 3_600, "Removed in under 1 min"),
        (30 * 3_600, "Removed in under 1 min"),
    ]

    @Test(arguments: countdownCases)
    func testCountdownText(elapsed: TimeInterval, expected: String) async throws {
        let id = try await deleteRecording(title: "Counting")
        await viewModel.refresh()

        now = start.addingTimeInterval(elapsed)

        #expect(viewModel.countdownText(for: try row(id)) == expected)
    }

    // MARK: - Revert

    @Test
    func testRevertRestoresTheSessionAnnouncesItAndSelectsIt() async throws {
        let id = try await deleteRecording(title: "Back")
        await viewModel.refresh()
        viewModel.open()
        announcements.removeAll()

        let selected = await viewModel.revert(try row(id), context: context)

        #expect(selected == id)
        #expect(try storedRecordingIDs() == [id])
        #expect(!FileManager.default.fileExists(atPath: holding.heldFolder(for: id).path))
        #expect(announcements == [SessionDeletionCoordinator.restoredAnnouncement])
        #expect(!viewModel.isOpen)
        #expect(viewModel.rows.isEmpty)
    }

    @Test
    func testRevertingOneOfSeveralClosesTheViewForTheSelectionAndKeepsTheRest() async throws {
        let first = try await deleteRecording(title: "Stays")
        let second = try await deleteRecording(title: "Goes back")
        await viewModel.refresh()
        viewModel.open()

        let selected = await viewModel.revert(try row(second), context: context)

        #expect(selected == second)
        #expect(!viewModel.isOpen)
        #expect(viewModel.rows.map(\.id) == [first])
        #expect(viewModel.isEntryEnabled)
    }

    @Test
    func testRevertRemovesTheUndoEntrySoALaterUndoDoesNothing() async throws {
        let id = try await deleteRecording(title: "Once")
        await viewModel.refresh()

        _ = await viewModel.revert(try row(id), context: context)

        #expect(!undoManager.canUndo)
        undoManager.undo()
        await coordinator.waitUntilIdle()
        #expect(try storedRecordingIDs() == [id])
    }

    @Test
    func testRevertRemovesOnlyThatSessionsUndoEntry() async throws {
        let kept = try await deleteRecording(title: "Still undoable")
        let reverted = try await deleteRecording(title: "Reverted")
        await viewModel.refresh()

        _ = await viewModel.revert(try row(reverted), context: context)

        #expect(undoManager.canUndo)
        undoManager.undo()
        await coordinator.waitUntilIdle()
        #expect(Set(try storedRecordingIDs()) == [kept, reverted])
    }

    @Test
    func testRevertWorksAfterARelaunchWithNoUndoEntry() async throws {
        let id = try await deleteRecording(title: "After relaunch")
        let relaunchedCoordinator = makeCoordinator()
        let relaunched = makeViewModel(coordinator: relaunchedCoordinator)
        await relaunched.refresh()

        let selected = await relaunched.revert(try #require(relaunched.rows.first), context: context)

        #expect(selected == id)
        #expect(try storedRecordingIDs() == [id])
    }

    @Test
    func testAFailedRevertSelectsNothingAndKeepsTheRow() async throws {
        let session = try makeRecording(title: "Occupied")
        let id = session.id
        let folder = URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
        _ = await coordinator.delete(session, context: context, undoManager: undoManager)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await viewModel.refresh()
        viewModel.open()

        let selected = await viewModel.revert(try row(id), context: context)

        #expect(selected == nil)
        #expect(viewModel.isOpen)
        #expect(viewModel.rows.map(\.id) == [id])
        #expect(try storedRecordingIDs().isEmpty)
    }

    // MARK: - Remove now

    @Test
    func testRemoveNowRemovesTheHeldFolderAndKeepsTheViewOpenWhileRowsRemain() async throws {
        let first = try await deleteRecording(title: "Remains")
        let second = try await deleteRecording(title: "Removed")
        await viewModel.refresh()
        viewModel.open()

        let result = await viewModel.removeNow(try row(second))

        #expect(result == .removed)
        #expect(!FileManager.default.fileExists(atPath: holding.heldFolder(for: second).path))
        #expect(viewModel.rows.map(\.id) == [first])
        #expect(viewModel.isOpen)
        #expect(try storedRecordingIDs().isEmpty)
    }

    @Test
    func testRemovingTheLastRowClosesTheView() async throws {
        let id = try await deleteRecording(title: "Last")
        await viewModel.refresh()
        viewModel.open()

        _ = await viewModel.removeNow(try row(id))

        #expect(!viewModel.isOpen)
        #expect(!viewModel.isEntryEnabled)
    }

    @Test
    func testRemoveNowRemovesTheUndoEntrySoALaterUndoDoesNothing() async throws {
        let id = try await deleteRecording(title: "Gone")
        await viewModel.refresh()

        _ = await viewModel.removeNow(try row(id))

        #expect(!undoManager.canUndo)
        undoManager.undo()
        await coordinator.waitUntilIdle()
        #expect(try storedRecordingIDs().isEmpty)
    }

    @Test
    func testRemoveNowAnnouncesNothing() async throws {
        let id = try await deleteRecording(title: "Quiet")
        await viewModel.refresh()
        announcements.removeAll()

        _ = await viewModel.removeNow(try row(id))

        #expect(announcements.isEmpty)
    }

    @Test
    func testAFailedRemoveNowReportsTheFolderLeftOnDisk() async throws {
        let id = try await deleteRecording(title: "Stuck")
        await viewModel.refresh()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: holding.url.path)

        let result = await viewModel.removeNow(try row(id))

        #expect(result == .folderLeft(holding.heldFolder(for: id)))
    }
}
