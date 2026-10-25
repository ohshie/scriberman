import Combine
import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// A clock the test moves by hand. Scheduled actions run when it passes their time.
@MainActor
private final class TestClock {
    private final class Entry: @unchecked Sendable {
        let date: Date
        let action: @MainActor () -> Void
        var isCancelled = false

        init(date: Date, action: @escaping @MainActor () -> Void) {
            self.date = date
            self.action = action
        }
    }

    private(set) var now: Date
    private var scheduled: [Entry] = []

    init(now: Date) {
        self.now = now
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AnyCancellable {
        let entry = Entry(date: now.addingTimeInterval(delay), action: action)
        scheduled.append(entry)
        return AnyCancellable { entry.isCancelled = true }
    }

    /// Moves the clock and runs, in time order, every action that is due and not cancelled.
    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
        let due = scheduled.filter { $0.date <= now }.sorted { $0.date < $1.date }
        scheduled.removeAll { $0.date <= now }
        for entry in due where !entry.isCancelled {
            entry.action()
        }
    }
}

@MainActor
final class SessionExpiryTests {
    private let workspace: Workspace
    private let workspaceService = MockWorkspaceService()
    private let container: ModelContainer
    private let context: ModelContext
    private let undoManager = UndoManager.forTests()
    private let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
    private lazy var coordinator = SessionDeletionCoordinator(
        workspaceService: workspaceService,
        now: { [clock] in clock.now },
        announce: { _ in },
        scheduleExpiry: { [clock] delay, action in clock.schedule(after: delay, action) }
    )

    private let day: TimeInterval = 24 * 60 * 60

    init() throws {
        workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: workspace.recordingsURL, withIntermediateDirectories: true)
        workspaceService.currentWorkspaceResult = workspace
        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    deinit {
        try? FileManager.default.removeItem(at: workspace.rootURL)
    }

    // MARK: - Fixtures

    private var holding: HoldingFolder { HoldingFolder(workspace: workspace) }

    private func makeRecording(named name: String = "Recording A") throws -> (RecordingSession, URL) {
        let folder = workspace.recordingsURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appendingPathComponent("mic.wav"))
        let session = RecordingSession(
            duration: 60,
            micAudioURL: folder.appendingPathComponent("mic.wav").path,
            title: name,
            status: .done
        )
        context.insert(session)
        try context.save()
        return (session, folder)
    }

    private func storedRecordings() throws -> [RecordingSession] {
        try ModelContext(container).fetch(FetchDescriptor<RecordingSession>())
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func advance(by interval: TimeInterval) async {
        clock.advance(by: interval)
        await coordinator.waitUntilIdle()
    }

    // MARK: - Expiry

    @Test
    func testAHeldSessionIsRemovedAt24HoursAndNotBefore() async throws {
        let (session, _) = try makeRecording()
        let id = session.id
        await coordinator.delete(session, context: context, undoManager: undoManager)

        await advance(by: day - 1)

        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))

        await advance(by: 1)

        #expect(!exists(holding.heldFolder(for: id)))
        #expect(try storedRecordings().isEmpty)
    }

    @Test
    func testExpiryRemovesTheUndoEntryOfThatSessionOnly() async throws {
        let (first, _) = try makeRecording(named: "First")
        await coordinator.delete(first, context: context, undoManager: undoManager)
        await advance(by: 60 * 60)
        let (second, _) = try makeRecording(named: "Second")
        let secondID = second.id
        await coordinator.delete(second, context: context, undoManager: undoManager)

        await advance(by: day - 60 * 60)

        #expect(undoManager.canUndo)
        undoManager.undo()
        await coordinator.waitUntilIdle()
        #expect(try storedRecordings().map(\.id) == [secondID])
        #expect(!undoManager.canUndo)
    }

    @Test
    func testExpiryLeavesNoUndoEntry() async throws {
        let (session, _) = try makeRecording()
        await coordinator.delete(session, context: context, undoManager: undoManager)

        await advance(by: day)

        #expect(!undoManager.canUndo)
        #expect(!undoManager.canRedo)
    }

    @Test
    func testRedoRestartsThe24Hours() async throws {
        let (session, folder) = try makeRecording()
        let id = session.id
        await coordinator.delete(session, context: context, undoManager: undoManager)
        await advance(by: 60 * 60)
        undoManager.undo()
        await coordinator.waitUntilIdle()
        await advance(by: 60 * 60)
        undoManager.redo()
        await coordinator.waitUntilIdle()

        await advance(by: day - 1)

        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))
        #expect(!exists(folder))

        await advance(by: 1)

        #expect(!exists(holding.heldFolder(for: id)))
        #expect(!undoManager.canUndo)
    }

    @Test
    func testARestoredSessionIsNotRemovedWhenItsTimeComes() async throws {
        let (session, folder) = try makeRecording()
        let id = session.id
        await coordinator.delete(session, context: context, undoManager: undoManager)
        undoManager.undo()
        await coordinator.waitUntilIdle()

        await advance(by: day * 2)

        #expect(try storedRecordings().map(\.id) == [id])
        #expect(exists(folder.appendingPathComponent("mic.wav")))
    }

    @Test
    func testASessionHeldInAWorkspaceThatIsNotActiveIsNotRemoved() async throws {
        let (session, _) = try makeRecording()
        let id = session.id
        await coordinator.delete(session, context: context, undoManager: undoManager)
        workspaceService.currentWorkspaceResult = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true))

        await advance(by: day)

        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))
    }

    @Test
    func testAFailedRemovalIsLoggedAndLeavesTheSessionHeld() async throws {
        let (session, _) = try makeRecording()
        let id = session.id
        await coordinator.delete(session, context: context, undoManager: undoManager)
        let held = holding.heldFolder(for: id)
        // A read-only held folder: nothing in it can be removed.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: held.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: held.path) }

        await advance(by: day)

        #expect(SessionSnapshot.exists(in: held))
        #expect(undoManager.canUndo)
    }

    /// Restore first or expiry first, the session ends either restored or removed, never both or
    /// neither.
    @Test(arguments: [true, false])
    func testAnExpiryRacingARestoreEndsInExactlyOneState(restoreFirst: Bool) async throws {
        let (session, folder) = try makeRecording()
        let id = session.id
        await coordinator.delete(session, context: context, undoManager: undoManager)

        if restoreFirst {
            undoManager.undo()
            clock.advance(by: day)
        } else {
            clock.advance(by: day)
            undoManager.undo()
        }
        await coordinator.waitUntilIdle()

        let restored = try storedRecordings().map(\.id) == [id] && exists(folder.appendingPathComponent("mic.wav"))
        let removed = try storedRecordings().isEmpty && !exists(folder) && !exists(holding.heldFolder(for: id))
        #expect(restored != removed)
        #expect(restored == restoreFirst)
    }

    // MARK: - Holding folder removal

    @Test
    func testRemovingAHeldSessionDeletesItsSubfolder() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: holding.heldFolder(for: id), withIntermediateDirectories: true)

        try holding.remove(sessionID: id)

        #expect(!exists(holding.heldFolder(for: id)))
        #expect(exists(holding.url))
    }

    @Test
    func testRemovingAHeldSessionThatIsGoneOrRemovedTwiceSucceeds() throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: holding.heldFolder(for: id), withIntermediateDirectories: true)

        try holding.remove(sessionID: id)
        try holding.remove(sessionID: id)
        try holding.remove(sessionID: UUID())
    }

    @Test
    func testRemovalRefusesAHoldingFolderThatLeadsOutsideTheWorkspace() throws {
        let id = UUID()
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: holding.url, withDestinationURL: outside)

        #expect(throws: HoldingFolder.HoldingError.self) { try holding.remove(sessionID: id) }
        #expect(exists(outside.appendingPathComponent(id.uuidString)))
    }
}
