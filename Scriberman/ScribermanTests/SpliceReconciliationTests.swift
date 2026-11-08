import Combine
import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
struct SpliceReconciliationTests {
    @Test(arguments: Array(1...16))
    func interruptedSpliceReopensTheStore(step: Int) async throws {
        let f = try ReconciliationFixture()
        let stop = RecoveryStop(step)
        try await f.splice(stop: stop)
        #expect(stop.stopped)
        try f.reopen()
        await f.reconcile()
        try f.assertRecovered(committed: stop.saved, restoring: false)
        await f.reconcile()
        try f.assertRecovered(committed: stop.saved, restoring: false)
    }

    @Test(arguments: Array(1...15))
    func interruptedResliceKeepsTheFirstOriginals(step: Int) async throws {
        let f = try ReconciliationFixture()
        try await f.splice()
        try f.captureBefore()
        let stop = RecoveryStop(step)
        try await f.splice(stop: stop)
        #expect(stop.stopped)
        try f.reopen()
        await f.reconcile()
        try f.assertRecovered(committed: stop.saved, restoring: false, reslicing: true)
    }

    @Test(arguments: Array(1...11))
    func interruptedRestoreFinishesMemberHoldsAfterTheSave(step: Int) async throws {
        let f = try ReconciliationFixture()
        try await f.splice()
        try f.captureBefore()
        let stop = RecoveryStop(step)
        try await f.restore(stop: stop)
        #expect(stop.stopped)
        try f.reopen()
        await f.reconcile()
        try f.assertRecovered(committed: stop.saved, restoring: true)
        await f.reconcile()
        try f.assertRecovered(committed: stop.saved, restoring: true)
    }

    @Test(arguments: ["splice", "reslice", "restore"], Array(1...12))
    func rollbackCanItselfBeInterruptedAndRetried(operation: String, step: Int) async throws {
        let f = try ReconciliationFixture()
        if operation != "splice" { try await f.splice(); try f.captureBefore() }
        if operation == "restore" { try await f.restore(stop: RecoveryStop(6)) }
        else { try await f.splice(stop: RecoveryStop(operation == "splice" ? 13 : 12)) }
        try f.reopen()
        let stop = RecoveryStop(step, alreadyArmed: true)
        await f.reconcile(files: stop.files())
        try f.reopen()
        await f.reconcile()
        try f.assertRecovered(committed: false, restoring: operation == "restore")
    }

    @Test(arguments: ["unreadable", "outside", "version", "unknownStore"])
    func unknownJournalsAreLeftUntouched(reason: String) async throws {
        let f = try ReconciliationFixture()
        try await f.splice(stop: RecoveryStop(4))
        let journalURL = try #require(f.journals().first)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        switch reason {
        case "unreadable": try Data([0]).write(to: journalURL)
        case "outside":
            object["newFolders"] = [f.root.absoluteString]
            try JSONSerialization.data(withJSONObject: object).write(to: journalURL)
        case "version":
            object["formatVersion"] = 99
            try JSONSerialization.data(withJSONObject: object).write(to: journalURL)
        default:
            let target = try f.target()
            target.duration = 123
            try f.context!.save()
        }
        let before = try f.tree(at: journalURL.deletingLastPathComponent())
        try f.reopen()
        await f.reconcile()
        #expect(try f.tree(at: journalURL.deletingLastPathComponent()) == before)
    }
}

@MainActor
private final class RecoveryStop {
    let step: Int
    var count = 0
    var armed: Bool
    var stopped = false
    var saved = false
    init(_ step: Int, alreadyArmed: Bool = false) { self.step = step; armed = alreadyArmed }
    func hit() throws {
        guard armed else { return }
        count += 1
        if count == step { stopped = true; throw SpliceFileOperations.Interruption() }
    }
    func files() -> SpliceFileOperations {
        var files = SpliceFileOperations()
        files.write = { data, url in
            try data.write(to: url, options: .atomic)
            if url.lastPathComponent == SpliceJournal.fileName { self.armed = true }
            try self.hit()
        }
        files.move = { from, to in try FileManager.default.moveItem(at: from, to: to); try self.hit() }
        files.remove = { url in try FileManager.default.removeItem(at: url); try self.hit() }
        files.checkpoint = { checkpoint in
            if checkpoint == .storeSaved { self.saved = true }
            try self.hit()
        }
        return files
    }
}

@MainActor
private final class ReconciliationFixture {
    let root: URL
    let workspace: Workspace
    let targetID: UUID
    let originalFolder: URL
    let originalAudio = Data("Full original audio".utf8)
    let originalVideo = Data("Full original video".utf8)
    var container: ModelContainer?
    var context: ModelContext?
    var coordinator: SessionDeletionCoordinator?
    var beforeRecords: [RecordingSessionRecord] = []
    var beforeTree: [String: Data] = [:]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        workspace = Workspace(rootURL: root.appendingPathComponent("workspace"))
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        originalFolder = try RecordingFileLayout.createRecordingFolder(in: workspace, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let session = RecordingSession(createdAt: Date(timeIntervalSince1970: 1_800_000_000), duration: 30,
            micAudioURL: originalFolder.appendingPathComponent("mic.wav").path,
            screenVideoURL: originalFolder.appendingPathComponent("screen.mov").path,
            mixdownURL: originalFolder.appendingPathComponent("recording.m4a").path, title: "Original", status: .done)
        targetID = session.id
        try reopen()
        try originalAudio.write(to: URL(fileURLWithPath: session.mixdownURL!))
        try originalVideo.write(to: URL(fileURLWithPath: session.screenVideoURL!))
        session.transcript = Transcript(fullText: "Words", segments: [(0, 1), (3, 4), (6, 7), (13, 17), (23, 30)].map {
            TranscriptSegment(speakerId: "A", text: "Words", startTime: Float($0.0), endTime: Float($0.1))
        }, speakers: [])
        context!.insert(session)
        try writeTranscriptMarkdown(for: session, writeEmpty: true)
        try context!.save()
        try captureBefore()
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func reopen() throws {
        coordinator = nil
        context = nil
        container = nil
        container = try ModelContainer(for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("store.sqlite")))
        context = ModelContext(container!)
        context!.autosaveEnabled = false
    }
    func target() throws -> RecordingSession { try #require(try RecordingSession.fetch(id: targetID, in: context!)) }
    func makeCoordinator() -> SessionDeletionCoordinator {
        SessionDeletionCoordinator(workspaceService: ReconciliationWorkspace(workspace: workspace), announce: { _ in },
            startAccess: { _ in false }, stopAccess: { _ in }, scheduleExpiry: { _, _ in AnyCancellable {} })
    }
    func service(files: SpliceFileOperations = SpliceFileOperations()) -> SpliceService {
        SpliceService(files: files, capacityProvider: { _ in .max }, export: { source, destination, start, end in
            try (Data("\(start)..\(end):".utf8) + Data(contentsOf: source)).write(to: destination)
        }, reconciliationCoordinator: coordinator)
    }
    func splice(stop: RecoveryStop? = nil) async throws {
        let session = try target()
        let plan = SplicePlan(cuts: session.duration == 30 ? [10, 20] : [2, 5],
            parts: [.init(title: "One"), .init(title: "Two"), .init(title: "Three")],
            transcriptFingerprint: SplicePlan.fingerprint(transcriptData: session.transcriptData, retranscriptData: session.retranscriptData))
        do { _ = try await service(files: stop?.files() ?? SpliceFileOperations()).splice(
            session: session, plan: plan, workspace: workspace, context: context!) }
        catch is SpliceFileOperations.Interruption {}
    }
    func restore(stop: RecoveryStop) async throws {
        coordinator = makeCoordinator()
        await coordinator!.activate(workspace, context: context!)
        do { _ = try await service(files: stop.files()).restore(
            session: target(), workspace: workspace, context: context!, coordinator: coordinator!) }
        catch is SpliceFileOperations.Interruption {}
        await coordinator!.waitUntilIdle()
    }
    func reconcile(files: SpliceFileOperations = SpliceFileOperations()) async {
        coordinator = makeCoordinator()
        await coordinator!.activate(workspace, context: context!)
        await service(files: files).reconcile(workspace: workspace, context: context!)
        await coordinator!.waitUntilIdle()
    }
    func captureBefore() throws {
        beforeRecords = try context!.fetch(FetchDescriptor<RecordingSession>()).map(RecordingSessionRecord.init).sorted { $0.id.uuidString < $1.id.uuidString }
        beforeTree = try tree(at: workspace.rootURL)
    }
    func journals() throws -> [URL] {
        let parent = workspace.rootURL.appendingPathComponent("splice")
        guard FileManager.default.fileExists(atPath: parent.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent(SpliceJournal.fileName) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    func tree(at url: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(url.path.count))] = try Data(contentsOf: file)
        }
        return result
    }
    func assertRecovered(committed: Bool, restoring: Bool, reslicing: Bool = false) throws {
        #expect(try journals().isEmpty)
        let entries = try FileManager.default.contentsOfDirectory(at: workspace.rootURL, includingPropertiesForKeys: nil)
        #expect(!entries.contains { $0.lastPathComponent.hasPrefix("_splice_") || $0.lastPathComponent.hasPrefix("_restore_") })
        let records = try context!.fetch(FetchDescriptor<RecordingSession>()).map(RecordingSessionRecord.init).sorted { $0.id.uuidString < $1.id.uuidString }
        if !committed {
            #expect(records == beforeRecords)
            #expect(try tree(at: workspace.rootURL) == beforeTree)
        } else if restoring {
            #expect(records.count == 1)
            #expect(try target().spliceGroupID == nil)
            #expect(try target().duration == 30)
            #expect(try Data(contentsOf: originalFolder.appendingPathComponent("recording.m4a")) == originalAudio)
            #expect(try Data(contentsOf: originalFolder.appendingPathComponent("screen.mov")) == originalVideo)
            #expect(try HoldingFolder(workspace: workspace).snapshotsForMembership().count == 2)
        } else {
            #expect(records.count == (reslicing ? 5 : 3))
            let group = try SpliceService.groupFolder(#require(target().spliceGroupID), workspace: workspace)
            #expect(try Data(contentsOf: group.appendingPathComponent("recording.m4a")) == originalAudio)
            #expect(try Data(contentsOf: group.appendingPathComponent("screen.mov")) == originalVideo)
            #expect(try target().duration == (reslicing ? 2 : 10))
            for record in records {
                #expect(FileManager.default.fileExists(atPath: record.mixdownURL!))
                #expect(FileManager.default.fileExists(atPath: record.screenVideoURL!))
            }
        }
    }
}
