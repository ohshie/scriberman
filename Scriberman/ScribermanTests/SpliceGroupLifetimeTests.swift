import Combine
import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
struct SpliceGroupLifetimeTests {
    @Test
    func permanentRemovalWaitsForBothLiveAndHeldMembers() async throws {
        let f = try LifetimeFixture()
        let group = try await f.splice()
        try await f.delete(group.memberIDs[0])
        #expect(await f.coordinator.removeHeld(group.memberIDs[0], context: f.context) == .removed)
        #expect(try Data(contentsOf: group.folder.appendingPathComponent("recording.m4a")) == group.originalAudio)
        try await f.delete(group.memberIDs[1])
        #expect(FileManager.default.fileExists(atPath: group.folder.path))
        #expect(await f.coordinator.removeHeld(group.memberIDs[1], context: f.context) == .removed)
        #expect(!FileManager.default.fileExists(atPath: group.folder.path))
    }

    @Test
    func deletingAllMembersStillAllowsRecoveryAndRestoreWithinADay() async throws {
        let f = try LifetimeFixture()
        let group = try await f.splice()
        for id in group.memberIDs { try await f.delete(id) }
        #expect(try f.context.fetch(FetchDescriptor<RecordingSession>()).isEmpty)
        f.clock.advance(by: SessionDeletionCoordinator.holdDuration - 1)
        await f.coordinator.waitUntilIdle()
        #expect(await f.coordinator.removeHeld(group.memberIDs[0], context: f.context) == .removed)
        #expect(FileManager.default.fileExists(atPath: group.folder.path))
        #expect(await f.coordinator.restoreHeld(group.memberIDs[1], context: f.context))
        let recovered = try f.member(group.memberIDs[1])
        #expect(recovered.spliceGroupID == group.id)
        _ = try await SpliceService().restore(session: recovered, workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        #expect(recovered.spliceGroupID == nil)
        #expect(recovered.duration == 20)
        #expect(try Data(contentsOf: URL(fileURLWithPath: recovered.mixdownURL!)) == group.originalAudio)
    }

    @Test
    func timerExpiryKeepsTheGroupUntilTheLastHeldMemberExpires() async throws {
        let f = try LifetimeFixture()
        let group = try await f.splice()
        let halfDay = SessionDeletionCoordinator.holdDuration / 2
        try await f.delete(group.memberIDs[0])
        f.clock.advance(by: halfDay)
        try await f.delete(group.memberIDs[1])
        f.clock.advance(by: halfDay)
        await f.coordinator.waitUntilIdle()
        #expect(await f.coordinator.heldSessions().map(\.sessionID) == [group.memberIDs[1]])
        #expect(FileManager.default.fileExists(atPath: group.folder.path))
        f.clock.advance(by: halfDay)
        await f.coordinator.waitUntilIdle()
        #expect(await f.coordinator.heldSessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: group.folder.path))
    }

    @Test
    func activationExpiresHeldMembersAndRemovesTheirUnusedGroup() async throws {
        let f = try LifetimeFixture()
        let group = try await f.splice()
        for id in group.memberIDs { try await f.delete(id) }
        f.clock.elapseWithoutRunning(by: SessionDeletionCoordinator.holdDuration + 1)
        let restarted = f.makeCoordinator()
        await restarted.activate(f.workspace, context: ModelContext(f.container))
        #expect(await restarted.heldSessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: group.folder.path))
    }

    @Test
    func activationInAnotherWorkspaceDoesNotRemoveTheFirstWorkspacesGroup() async throws {
        let f = try LifetimeFixture()
        let group = try await f.splice()
        for id in group.memberIDs { try await f.delete(id) }
        f.clock.elapseWithoutRunning(by: SessionDeletionCoordinator.holdDuration + 1)
        let other = Workspace(rootURL: f.workspace.rootURL.appendingPathComponent("other"))
        try FileManager.default.createDirectory(at: other.rootURL, withIntermediateDirectories: true)
        f.workspaceService.currentWorkspaceResult = other
        let restarted = f.makeCoordinator()
        await restarted.activate(other, context: f.context)
        #expect(FileManager.default.fileExists(atPath: group.folder.path))
        f.workspaceService.currentWorkspaceResult = f.workspace
        await restarted.activate(f.workspace, context: f.context)
        #expect(!FileManager.default.fileExists(atPath: group.folder.path))
    }

    @Test(arguments: ["snapshot", "missingSnapshot", "mismatchedID", "unknownFolder", "heldSymlink", "holdingSymlink", "holdingFile"])
    func unknownHoldingMembershipKeepsOriginals(reason: String) throws {
        let f = try LifetimeFixture()
        let group = try f.orphan()
        let holding = HoldingFolder(workspace: f.workspace)
        let id = UUID()
        var folder = holding.heldFolder(for: id)
        switch reason {
        case "holdingSymlink":
            let elsewhere = f.workspace.rootURL.appendingPathComponent("elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: holding.url, withDestinationURL: elsewhere)
        case "holdingFile": try Data([0]).write(to: holding.url)
        case "heldSymlink":
            try FileManager.default.createDirectory(at: holding.url, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: group.folder)
        default:
            if reason == "unknownFolder" { folder = holding.url.appendingPathComponent("unknown") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if reason == "snapshot" { try Data([0]).write(to: SessionSnapshot.url(in: folder)) }
            if reason == "mismatchedID" || reason == "unknownFolder" {
                let session = RecordingSession(duration: 1, micAudioURL: "unused", title: "Held")
                session.spliceGroupID = group.id
                try SessionSnapshot(recording: session, originalFolder: folder, deletedAt: f.clock.now).write(into: folder)
            }
        }
        let service = SpliceService()
        #expect(service.removeGroupIfUnused(group.id, workspace: f.workspace, context: f.context) == .membershipUnavailable)
        #expect(try Data(contentsOf: group.folder.appendingPathComponent("recording.m4a")) == group.originalAudio)
        #expect(service.sweepUnusedGroups(workspace: f.workspace, context: f.context)[group.id] == .membershipUnavailable)
    }

    @Test(arguments: ["store", "holding"])
    func failedMembershipReadKeepsTheGroupEvenAfterItsLastHeldMemberIsRemoved(reader: String) async throws {
        let f = try LifetimeFixture()
        let group = try await f.splice()
        var membership = SpliceMembershipReader()
        if reader == "store" { membership.liveGroupIDs = { _ in throw CocoaError(.fileReadUnknown) } }
        else { membership.heldGroupIDs = { _ in throw CocoaError(.fileReadNoPermission) } }
        let service = SpliceService(membership: membership)
        let coordinator = f.makeCoordinator(spliceService: service)
        for id in group.memberIDs {
            #expect(await coordinator.delete(try f.member(id), context: f.context, undoManager: nil) == .deleted)
        }
        for id in group.memberIDs { #expect(await coordinator.removeHeld(id, context: f.context) == .removed) }
        #expect(service.removeGroupIfUnused(group.id, workspace: f.workspace, context: f.context) == .membershipUnavailable)
        #expect(FileManager.default.fileExists(atPath: group.folder.path))
        #expect(SpliceService().removeGroupIfUnused(group.id, workspace: f.workspace, context: f.context) == .removed)
    }

    @Test
    func anUnreadableSnapshotKeepsTheGroupThroughExpiryAndActivationRetriesAfterRepair() async throws {
        let f = try LifetimeFixture()
        let group = try await f.splice()
        for id in group.memberIDs { try await f.delete(id) }
        let corrupt = HoldingFolder(workspace: f.workspace).heldFolder(for: UUID())
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data([0]).write(to: SessionSnapshot.url(in: corrupt))
        f.clock.advance(by: SessionDeletionCoordinator.holdDuration + 1)
        await f.coordinator.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: group.folder.path))
        await f.coordinator.activate(f.workspace, context: f.context)
        #expect(FileManager.default.fileExists(atPath: group.folder.path))
        try FileManager.default.removeItem(at: corrupt)
        await f.coordinator.activate(f.workspace, context: f.context)
        #expect(!FileManager.default.fileExists(atPath: group.folder.path))
    }

    @Test
    func aJournalAlwaysKeepsAnOtherwiseUnusedGroup() async throws {
        let f = try LifetimeFixture()
        let group = try await f.splice()
        for id in group.memberIDs { try await f.delete(id) }
        let journal = group.folder.appendingPathComponent(SpliceJournal.fileName)
        try Data("unreadable journal".utf8).write(to: journal)
        for id in group.memberIDs { #expect(await f.coordinator.removeHeld(id, context: f.context) == .removed) }
        #expect(SpliceService().removeGroupIfUnused(group.id, workspace: f.workspace, context: f.context) == .journalPresent)
        await f.coordinator.activate(f.workspace, context: f.context)
        #expect(try Data(contentsOf: journal) == Data("unreadable journal".utf8))
        #expect(FileManager.default.fileExists(atPath: group.folder.path))
    }

    @Test(arguments: ["insert", "detach", "delete"])
    func pendingChangesCannotMakeSavedOrNewMembershipDisappear(change: String) throws {
        let f = try LifetimeFixture()
        let group = try f.orphan()
        let session = RecordingSession(duration: 1, micAudioURL: "unused", title: "Member")
        session.spliceGroupID = group.id
        f.context.insert(session)
        if change != "insert" { try f.context.save() }
        if change == "detach" { session.spliceGroupID = nil }
        if change == "delete" { f.context.delete(session) }
        #expect(SpliceService().removeGroupIfUnused(group.id, workspace: f.workspace, context: f.context) == .inUse)
        #expect(FileManager.default.fileExists(atPath: group.folder.path))
    }

    @Test
    func missingHoldingFolderMeansNoHeldMembershipAndSweepKeepsUnrelatedLiveGroups() async throws {
        let f = try LifetimeFixture()
        let unused = try f.orphan()
        let live = try await f.splice()
        let results = SpliceService().sweepUnusedGroups(workspace: f.workspace, context: f.context)
        #expect(results[unused.id] == .removed)
        #expect(results[live.id] == .inUse)
        #expect(!FileManager.default.fileExists(atPath: unused.folder.path))
        #expect(FileManager.default.fileExists(atPath: live.folder.path))
    }

    @Test
    func validNonGroupSnapshotsAndFinderMetadataDoNotBlockUnusedGroupRemoval() throws {
        let f = try LifetimeFixture()
        let group = try f.orphan()
        let holding = HoldingFolder(workspace: f.workspace)
        let imported = ImportedSession(duration: 1, mixdownURL: "unused", title: "Import", originalFileName: "source.wav", originalFormat: "wav")
        let held = holding.heldFolder(for: imported.id)
        try SessionSnapshot(imported: imported, originalFolder: f.workspace.importsURL.appendingPathComponent("Import"), deletedAt: f.clock.now)
            .write(into: held)
        try Data([0]).write(to: holding.url.appendingPathComponent(".DS_Store"))
        #expect(SpliceService().removeGroupIfUnused(group.id, workspace: f.workspace, context: f.context) == .removed)
        #expect(try SessionSnapshot.read(from: held).sessionID == imported.id)
    }

    @Test
    func removalFailureKeepsTheGroupForALaterActivation() async throws {
        let f = try LifetimeFixture()
        let group = try f.orphan()
        var files = SpliceFileOperations()
        files.remove = { _ in throw CocoaError(.fileWriteNoPermission) }
        #expect(SpliceService(files: files).removeGroupIfUnused(group.id, workspace: f.workspace, context: f.context) == .removalFailed)
        #expect(try Data(contentsOf: group.folder.appendingPathComponent("recording.m4a")) == group.originalAudio)
        await f.coordinator.activate(f.workspace, context: f.context)
        #expect(!FileManager.default.fileExists(atPath: group.folder.path))
    }

    @Test
    func groupCleanupNeverFollowsASymlinkOutsideItsOwnedPath() throws {
        let f = try LifetimeFixture()
        let group = try f.orphan()
        let elsewhere = f.workspace.rootURL.appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: group.folder, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: group.folder, withDestinationURL: elsewhere)
        let service = SpliceService()
        #expect(service.removeGroupIfUnused(group.id, workspace: f.workspace, context: f.context) == .invalidPath)
        #expect(service.sweepUnusedGroups(workspace: f.workspace, context: f.context)[group.id] == .invalidPath)
        #expect(try Data(contentsOf: elsewhere.appendingPathComponent("recording.m4a")) == group.originalAudio)
    }
}

@MainActor
private final class LifetimeClock {
    private final class Entry {
        let date: Date
        let action: @MainActor () -> Void
        var cancelled = false
        init(date: Date, action: @escaping @MainActor () -> Void) { self.date = date; self.action = action }
    }
    private(set) var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var entries: [Entry] = []
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AnyCancellable {
        let entry = Entry(date: now.addingTimeInterval(delay), action: action)
        entries.append(entry)
        return AnyCancellable { entry.cancelled = true }
    }
    func elapseWithoutRunning(by interval: TimeInterval) { now.addTimeInterval(interval) }
    func advance(by interval: TimeInterval) {
        now.addTimeInterval(interval)
        let due = entries.filter { $0.date <= now }.sorted { $0.date < $1.date }
        entries.removeAll { $0.date <= now }
        for entry in due where !entry.cancelled { entry.action() }
    }
}

@MainActor
private final class LifetimeFixture {
    struct Group {
        let id: UUID
        let memberIDs: [UUID]
        let folder: URL
        let originalAudio: Data
    }
    let workspace: Workspace
    let workspaceService = MockWorkspaceService()
    let container: ModelContainer
    let context: ModelContext
    let clock = LifetimeClock()
    lazy var coordinator = makeCoordinator()

    init() throws {
        workspace = Workspace(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        workspaceService.currentWorkspaceResult = workspace
        container = try ModelContainer(for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        context.autosaveEnabled = false
    }
    deinit { try? FileManager.default.removeItem(at: workspace.rootURL) }

    func makeCoordinator(spliceService: SpliceService? = nil) -> SessionDeletionCoordinator {
        SessionDeletionCoordinator(workspaceService: workspaceService, now: { [clock] in clock.now },
            announce: { _ in }, startAccess: { _ in false }, stopAccess: { _ in },
            scheduleExpiry: { [clock] delay, action in clock.schedule(after: delay, action) }, spliceService: spliceService)
    }
    func member(_ id: UUID) throws -> RecordingSession { try #require(try RecordingSession.fetch(id: id, in: context)) }
    func delete(_ id: UUID) async throws {
        #expect(await coordinator.delete(try member(id), context: context, undoManager: nil) == .deleted)
    }
    func orphan() throws -> Group {
        let id = UUID()
        let folder = try SpliceService.groupFolder(id, workspace: workspace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data("original \(id)".utf8)
        try bytes.write(to: folder.appendingPathComponent("recording.m4a"))
        return Group(id: id, memberIDs: [], folder: folder, originalAudio: bytes)
    }
    func splice() async throws -> Group {
        let folder = try RecordingFileLayout.createRecordingFolder(in: workspace, createdAt: clock.now)
        let bytes = Data("full audio \(UUID())".utf8)
        try bytes.write(to: folder.appendingPathComponent("recording.m4a"))
        let session = RecordingSession(createdAt: clock.now, duration: 20,
            micAudioURL: folder.appendingPathComponent("mic.wav").path,
            mixdownURL: folder.appendingPathComponent("recording.m4a").path, title: "Original", status: .done)
        let segments = [TranscriptSegment(speakerId: "A", text: "First", startTime: 0, endTime: 5),
                        TranscriptSegment(speakerId: "A", text: "Second", startTime: 15, endTime: 20)]
        session.transcript = Transcript(fullText: "First Second", segments: segments, speakers: [])
        let tag = RecordingTag(name: "Work", colorHex: "112233")
        context.insert(tag); context.insert(session)
        session.tags = [tag]
        try context.save()
        let service = SpliceService(capacityProvider: { _ in .max }, export: { source, destination, start, end in
            try (Data("\(start)..\(end):".utf8) + Data(contentsOf: source)).write(to: destination)
        })
        let parts = try await service.splice(session: session,
            plan: SplicePlan(cuts: [10], parts: [.init(title: "First"), .init(title: "Second")],
                transcriptFingerprint: SplicePlan.fingerprint(transcriptData: session.transcriptData, retranscriptData: nil)),
            workspace: workspace, context: context)
        let id = try #require(session.spliceGroupID)
        return Group(id: id, memberIDs: parts.map(\.id), folder: try SpliceService.groupFolder(id, workspace: workspace), originalAudio: bytes)
    }
}
