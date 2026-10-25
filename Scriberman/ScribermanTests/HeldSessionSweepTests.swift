import Combine
import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// A clock the test moves by hand. Scheduled actions run when it passes their time.
@MainActor
private final class SweepClock {
    private final class Entry {
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

    /// Actions scheduled and neither run nor cancelled.
    var pendingCount: Int {
        scheduled.filter { !$0.isCancelled }.count
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AnyCancellable {
        let entry = Entry(date: now.addingTimeInterval(delay), action: action)
        scheduled.append(entry)
        return AnyCancellable { entry.isCancelled = true }
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
        let due = scheduled.filter { $0.date <= now }.sorted { $0.date < $1.date }
        scheduled.removeAll { $0.date <= now }
        for entry in due where !entry.isCancelled {
            entry.action()
        }
    }
}

/// Holds a job open, ignoring cancellation, until the test lets it go.
actor TestJobGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor MixdownCalls {
    private(set) var count = 0
    func record() { count += 1 }
}

@MainActor
final class HeldSessionSweepTests {
    private let workspace: Workspace
    private let workspaceService = MockWorkspaceService()
    private let container: ModelContainer
    private let context: ModelContext
    private let undoManager = UndoManager.forTests()
    private let clock = SweepClock(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
    private let sessionJobs = SessionJobs()
    private lazy var coordinator = SessionDeletionCoordinator(
        workspaceService: workspaceService,
        now: { [clock] in clock.now },
        announce: { _ in },
        scheduleExpiry: { [clock] delay, action in clock.schedule(after: delay, action) },
        sessionJobs: sessionJobs
    )

    private let hour: TimeInterval = 60 * 60
    private let day: TimeInterval = 24 * 60 * 60

    init() throws {
        workspace = Self.makeWorkspace()
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

    private static func makeWorkspace() -> Workspace {
        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        try? FileManager.default.createDirectory(at: workspace.recordingsURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: workspace.importsURL, withIntermediateDirectories: true)
        return workspace
    }

    // MARK: - Fixtures

    private var holding: HoldingFolder { HoldingFolder(workspace: workspace) }

    private func folderPath(_ kind: DeletedSessionKind, named name: String, in workspace: Workspace? = nil) -> URL {
        kind.area(of: workspace ?? self.workspace).appendingPathComponent(name, isDirectory: true)
    }

    private func fill(_ folder: URL, _ kind: DeletedSessionKind) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in kind.files {
            try Data(file.utf8).write(to: folder.appendingPathComponent(file))
        }
    }

    /// A session of `kind` whose folder is `folder`, inserted into the store when `stored`.
    private func makeSession(_ kind: DeletedSessionKind, folder: URL, stored: Bool) throws -> HeldFixture {
        let fixture: HeldFixture
        switch kind {
        case .recording:
            let session = RecordingSession(
                duration: 60,
                micAudioURL: folder.appendingPathComponent("mic.wav").path,
                mixdownURL: folder.appendingPathComponent("recording.m4a").path,
                title: "A",
                status: .done
            )
            if stored { context.insert(session) }
            fixture = .recording(session)
        case .imported:
            let session = ImportedSession(
                duration: 60,
                mixdownURL: folder.appendingPathComponent("recording.m4a").path,
                title: "A",
                originalFileName: "A.mp3",
                originalFormat: "mp3",
                status: .done
            )
            if stored { context.insert(session) }
            fixture = .imported(session)
        }
        if stored { try context.save() }
        return fixture
    }

    private func id(of fixture: HeldFixture) -> UUID {
        switch fixture {
        case .recording(let session): session.id
        case .imported(let session): session.id
        }
    }

    private func snapshot(of fixture: HeldFixture, folder: URL, deletedAt: Date) -> SessionSnapshot {
        switch fixture {
        case .recording(let session): SessionSnapshot(recording: session, originalFolder: folder, deletedAt: deletedAt)
        case .imported(let session): SessionSnapshot(imported: session, originalFolder: folder, deletedAt: deletedAt)
        }
    }

    /// A held subfolder for `fixture` with its files and a snapshot, as a delete leaves it.
    @discardableResult
    private func placeHeld(
        _ fixture: HeldFixture,
        _ kind: DeletedSessionKind,
        originalFolder: URL,
        deletedAt: Date
    ) throws -> URL {
        let held = holding.heldFolder(for: id(of: fixture))
        try fill(held, kind)
        try snapshot(of: fixture, folder: originalFolder, deletedAt: deletedAt).write(into: held)
        return held
    }

    /// A stored session of `kind` whose folder is in holding with a snapshot: a crash between the
    /// move and the save.
    private func makeUncommittedHold(_ kind: DeletedSessionKind, deletedAt: Date) throws -> (UUID, URL) {
        let folder = folderPath(kind, named: "Session")
        let fixture = try makeSession(kind, folder: folder, stored: true)
        try placeHeld(fixture, kind, originalFolder: folder, deletedAt: deletedAt)
        return (id(of: fixture), folder)
    }

    /// A committed delete from an earlier run: held with a snapshot, no record.
    private func makeCommittedHold(
        _ kind: DeletedSessionKind,
        named name: String = "Session",
        deletedAt: Date
    ) throws -> (UUID, URL) {
        let folder = folderPath(kind, named: name)
        let fixture = try makeSession(kind, folder: folder, stored: false)
        try placeHeld(fixture, kind, originalFolder: folder, deletedAt: deletedAt)
        return (id(of: fixture), folder)
    }

    private func storedIDs() throws -> Set<UUID> {
        let fresh = ModelContext(container)
        let recordings = try fresh.fetch(FetchDescriptor<RecordingSession>()).map(\.id)
        let imported = try fresh.fetch(FetchDescriptor<ImportedSession>()).map(\.id)
        return Set(recordings + imported)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func activate(_ workspace: Workspace? = nil) async {
        await coordinator.activate(workspace ?? self.workspace, context: context)
        await coordinator.waitUntilIdle()
    }

    private func advance(by interval: TimeInterval) async {
        clock.advance(by: interval)
        await coordinator.waitUntilIdle()
    }

    // MARK: - Reconcile

    @Test(arguments: DeletedSessionKind.allCases)
    func testAHeldFolderWhoseRecordStillExistsIsMovedBackAndLosesItsSnapshot(kind: DeletedSessionKind) async throws {
        let (id, folder) = try makeUncommittedHold(kind, deletedAt: clock.now)

        await activate()

        #expect(!exists(holding.heldFolder(for: id)))
        #expect(exists(folder.appendingPathComponent("recording.m4a")))
        #expect(!SessionSnapshot.exists(in: folder))
        #expect(try storedIDs() == [id])
    }

    @Test(arguments: DeletedSessionKind.allCases)
    func testAnUncommittedDeleteFoundMoreThan24HoursLaterIsMovedBackNotRemoved(kind: DeletedSessionKind) async throws {
        let (id, folder) = try makeUncommittedHold(kind, deletedAt: clock.now.addingTimeInterval(-3 * day))

        await activate()

        #expect(!exists(holding.heldFolder(for: id)))
        #expect(exists(folder.appendingPathComponent("recording.m4a")))
        #expect(!SessionSnapshot.exists(in: folder))
        #expect(try storedIDs() == [id])
    }

    @Test(arguments: DeletedSessionKind.allCases)
    func testASessionFolderWithASnapshotAndARecordLosesItsSnapshot(kind: DeletedSessionKind) async throws {
        let folder = folderPath(kind, named: "Session")
        try fill(folder, kind)
        let fixture = try makeSession(kind, folder: folder, stored: true)
        try snapshot(of: fixture, folder: folder, deletedAt: clock.now.addingTimeInterval(-3 * day)).write(into: folder)

        await activate()

        #expect(!SessionSnapshot.exists(in: folder))
        #expect(exists(folder.appendingPathComponent("recording.m4a")))
        #expect(!exists(holding.heldFolder(for: id(of: fixture))))
        #expect(try storedIDs() == [id(of: fixture)])
    }

    @Test(arguments: DeletedSessionKind.allCases)
    func testAHeldFolderWithASnapshotAnEmptyOriginalPathAndNoRecordStaysHeld(kind: DeletedSessionKind) async throws {
        let (id, folder) = try makeCommittedHold(kind, deletedAt: clock.now.addingTimeInterval(-hour))

        await activate()

        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))
        #expect(!exists(folder))
        #expect(try storedIDs().isEmpty)
        #expect(await coordinator.heldSessions().map(\.sessionID) == [id])
    }

    @Test(arguments: DeletedSessionKind.allCases)
    func testAFolderBackAtItsOriginalPathWithASnapshotAndNoRecordIsMovedBackIntoHolding(kind: DeletedSessionKind) async throws {
        let folder = folderPath(kind, named: "Session")
        try fill(folder, kind)
        let fixture = try makeSession(kind, folder: folder, stored: false)
        try snapshot(of: fixture, folder: folder, deletedAt: clock.now.addingTimeInterval(-hour)).write(into: folder)

        await activate()

        let held = holding.heldFolder(for: id(of: fixture))
        #expect(!exists(folder))
        #expect(SessionSnapshot.exists(in: held))
        #expect(exists(held.appendingPathComponent("recording.m4a")))
        #expect(try storedIDs().isEmpty)
    }

    @Test(arguments: DeletedSessionKind.allCases)
    func testAHeldFolderWithNoReadableSnapshotIsMovedBackWhenItsNameMatchesARecord(kind: DeletedSessionKind) async throws {
        let folder = folderPath(kind, named: "Session")
        let fixture = try makeSession(kind, folder: folder, stored: true)
        let held = holding.heldFolder(for: id(of: fixture))
        try fill(held, kind)
        try Data("not json".utf8).write(to: SessionSnapshot.url(in: held))

        await activate()

        #expect(!exists(held))
        #expect(exists(folder.appendingPathComponent("recording.m4a")))
        #expect(!SessionSnapshot.exists(in: folder))
        #expect(try storedIDs() == [id(of: fixture)])
    }

    @Test(arguments: [true, false])
    func testAHeldFolderWithNoReadableSnapshotAndNoRecordIsKeptAndNotListed(hasBrokenSnapshot: Bool) async throws {
        let id = UUID()
        let held = holding.heldFolder(for: id)
        try fill(held, .recording)
        if hasBrokenSnapshot {
            try Data("not json".utf8).write(to: SessionSnapshot.url(in: held))
        }
        try FileManager.default.setAttributes(
            [.modificationDate: clock.now.addingTimeInterval(-30 * day)],
            ofItemAtPath: held.path
        )

        await activate()
        await advance(by: 30 * day)
        await activate()

        #expect(exists(held.appendingPathComponent("mic.wav")))
        #expect(await coordinator.heldSessions().isEmpty)
    }

    @Test(arguments: DeletedSessionKind.allCases)
    func testAHeldFolderWhoseRecordExistsStaysHeldWhenItsOriginalPathIsOccupied(kind: DeletedSessionKind) async throws {
        let (id, folder) = try makeUncommittedHold(kind, deletedAt: clock.now.addingTimeInterval(-3 * day))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: folder.appendingPathComponent("other.txt"))

        await activate()

        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))
        #expect(exists(folder.appendingPathComponent("other.txt")))
        #expect(try storedIDs() == [id])
    }

    @Test
    func testRestoringIntoAnOccupiedOriginalPathIsRefusedAndTheSessionStaysHeld() async throws {
        let (id, folder) = try makeCommittedHold(.recording, deletedAt: clock.now.addingTimeInterval(-hour))
        await activate()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let restored = await coordinator.restoreHeld(id, context: context)

        #expect(!restored)
        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))
        #expect(try storedIDs().isEmpty)
    }

    @Test
    func testAnUncommittedHoldIsNotListedAfterTheSweep() async throws {
        let (committed, _) = try makeCommittedHold(.recording, named: "Committed", deletedAt: clock.now)
        _ = try makeUncommittedHold(.imported, deletedAt: clock.now)

        await activate()

        #expect(await coordinator.heldSessions().map(\.sessionID) == [committed])
    }

    // MARK: - Expire

    @Test(arguments: DeletedSessionKind.allCases)
    func testExpiredCommittedHoldsAreRemovedAndUnexpiredOnesKept(kind: DeletedSessionKind) async throws {
        let (expired, _) = try makeCommittedHold(kind, named: "Expired", deletedAt: clock.now.addingTimeInterval(-day - 1))
        let (kept, _) = try makeCommittedHold(kind, named: "Kept", deletedAt: clock.now.addingTimeInterval(-day + hour))

        await activate()

        #expect(!exists(holding.heldFolder(for: expired)))
        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: kept)))
    }

    @Test
    func testReconcileRunsBeforeExpire() async throws {
        // A crash during a restore, after the move back: reconcile moves it into holding, and
        // only then is it a committed delete that expire removes.
        let folder = folderPath(.recording, named: "Session")
        try fill(folder, .recording)
        let fixture = try makeSession(.recording, folder: folder, stored: false)
        try snapshot(of: fixture, folder: folder, deletedAt: clock.now.addingTimeInterval(-2 * day)).write(into: folder)

        await activate()

        #expect(!exists(folder))
        #expect(!exists(holding.heldFolder(for: id(of: fixture))))
    }

    @Test
    func testExpiringOnActivationRemovesTheUndoEntryOfThatSession() async throws {
        let folder = folderPath(.recording, named: "Session")
        try fill(folder, .recording)
        guard case .recording(let session) = try makeSession(.recording, folder: folder, stored: true) else { return }
        let id = session.id
        await coordinator.delete(session, context: context, undoManager: undoManager)
        let other = Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: other.rootURL) }
        workspaceService.currentWorkspaceResult = other
        await activate(other)
        await advance(by: 2 * day)

        workspaceService.currentWorkspaceResult = workspace
        await activate()

        #expect(!exists(holding.heldFolder(for: id)))
        #expect(!undoManager.canUndo)
    }

    // MARK: - Expiry timers

    @Test
    func testActivationStartsExpiryForEverySessionHeldInTheWorkspace() async throws {
        let (first, _) = try makeCommittedHold(.recording, named: "First", deletedAt: clock.now.addingTimeInterval(-day + hour))
        let (second, _) = try makeCommittedHold(.imported, named: "Second", deletedAt: clock.now.addingTimeInterval(-day + 2 * hour))
        await activate()

        await advance(by: hour)

        #expect(!exists(holding.heldFolder(for: first)))
        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: second)))

        await advance(by: hour)

        #expect(!exists(holding.heldFolder(for: second)))
    }

    @Test
    func testActivationStopsTheOldWorkspacesTimers() async throws {
        let folder = folderPath(.recording, named: "Session")
        try fill(folder, .recording)
        guard case .recording(let session) = try makeSession(.recording, folder: folder, stored: true) else { return }
        await coordinator.delete(session, context: context, undoManager: undoManager)
        #expect(clock.pendingCount == 1)
        let other = Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: other.rootURL) }

        workspaceService.currentWorkspaceResult = other
        await activate(other)

        #expect(clock.pendingCount == 0)
    }

    @Test
    func testReturningToAWorkspaceRestartsItsTimers() async throws {
        let (id, _) = try makeCommittedHold(.recording, deletedAt: clock.now.addingTimeInterval(-day + 2 * hour))
        await activate()
        let other = Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: other.rootURL) }
        workspaceService.currentWorkspaceResult = other
        await activate(other)
        await advance(by: hour)

        workspaceService.currentWorkspaceResult = workspace
        await activate()
        await advance(by: hour)

        #expect(!exists(holding.heldFolder(for: id)))
    }

    @Test
    func testActivationRefreshesThePendingDeletionsEntryPoint() async throws {
        _ = try makeCommittedHold(.recording, deletedAt: clock.now)
        let viewModel = PendingDeletionsViewModel(coordinator: coordinator, now: { [clock] in clock.now })
        let revision = coordinator.holdingChanges.revision

        await activate()

        #expect(coordinator.holdingChanges.revision > revision)
        await viewModel.refresh()
        #expect(viewModel.isEntryEnabled)
    }

    // MARK: - Operations in progress

    @Test
    func testAnOperationIsInProgressWhileADeleteRuns() async throws {
        let folder = folderPath(.recording, named: "Session")
        try fill(folder, .recording)
        guard case .recording(let session) = try makeSession(.recording, folder: folder, stored: true) else { return }
        let gate = TestJobGate()
        let job = Task { await gate.wait() }
        sessionJobs.track(job, as: sessionJobs.generation(of: session.id))
        #expect(!coordinator.hasOperationInProgress)

        let deletion = Task { await coordinator.delete(session, context: context, undoManager: undoManager) }
        // Let the delete start; it then waits on the job.
        for _ in 0..<20 { await Task.yield() }

        #expect(coordinator.hasOperationInProgress)
        #expect(exists(folder.appendingPathComponent("mic.wav")))
        await gate.open()
        _ = await deletion.value
        await coordinator.waitUntilIdle()
        #expect(!coordinator.hasOperationInProgress)
    }

    // MARK: - Crash recovery

    @Test
    func testCrashRecoveryNeverSeesAHeldSession() async throws {
        let folder = folderPath(.recording, named: "Session")
        let session = RecordingSession(
            duration: 60,
            micAudioURL: folder.appendingPathComponent("mic.wav").path,
            title: "A",
            status: .recorded
        )
        let held = holding.heldFolder(for: session.id)
        try fill(held, .recording)
        try SessionSnapshot(recording: session, originalFolder: folder, deletedAt: clock.now).write(into: held)
        let calls = MixdownCalls()
        let recovery = RecordingRecoveryService(
            workspaceService: workspaceService,
            modelContainer: container,
            performMixdown: { _, _, _, _ in await calls.record() },
            performMux: { _ in }
        )

        await activate()
        await recovery.sweepIncompleteSessions()

        #expect(await calls.count == 0)
        #expect(SessionSnapshot.exists(in: held))
        #expect(exists(held.appendingPathComponent("mic.wav")))
        #expect(try storedIDs().isEmpty)
    }
}
