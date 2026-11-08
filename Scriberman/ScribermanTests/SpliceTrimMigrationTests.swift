import Combine
import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
struct SpliceTrimMigrationTests {
    @Test(arguments: [false, true])
    func reconcileMigratesALiveTrimmedSessionIntoAGroupOfOne(video: Bool) async throws {
        let f = try TrimMigrationFixture(video: video)
        await f.reconcile()

        let session = try f.target()
        let groupID = try #require(session.spliceGroupID)
        let group = try SpliceService.groupFolder(groupID, workspace: f.workspace)
        #expect(try Data(contentsOf: group.appendingPathComponent("recording.m4a")) == TrimMigrationFixture.originalAudio)
        #expect(FileManager.default.fileExists(atPath: group.appendingPathComponent("screen.mov").path) == video)
        if video { #expect(try Data(contentsOf: group.appendingPathComponent("screen.mov")) == TrimMigrationFixture.originalVideo) }
        #expect(!FileManager.default.fileExists(atPath: f.originalAudioURL.path))
        #expect(!FileManager.default.fileExists(atPath: f.originalVideoURL.path))
        #expect(try Data(contentsOf: f.audioURL) == TrimMigrationFixture.trimmedAudio)
        if video { #expect(try Data(contentsOf: f.videoURL) == TrimMigrationFixture.trimmedVideo) }
        #expect(!FileManager.default.fileExists(atPath: group.appendingPathComponent(SpliceJournal.fileName).path))

        let manifest = try JSONDecoder().decode(SpliceManifest.self, from: Data(contentsOf: group.appendingPathComponent(SpliceManifest.fileName)))
        #expect(manifest.originalSessionID == f.targetID)
        #expect(manifest.duration == 120)
        #expect(manifest.title == "Trimmed")
        #expect(manifest.createdAt == f.start)
        #expect(manifest.transcriptData == f.fullTranscriptData)
        #expect(manifest.retranscriptData == f.fullRetranscriptData)
        #expect(manifest.hasScreenVideo == video)

        try f.reopen()
        let saved = try f.target()
        #expect(saved.spliceGroupID == groupID)
        #expect(saved.duration == 60)
        #expect(saved.createdAt == f.start)
        #expect(saved.title == "Trimmed")
        #expect(saved.transcriptData == f.trimmedTranscriptData)
        #expect(saved.retranscriptData == f.trimmedRetranscriptData)
        #expect(saved.originalMixdownURL == nil)
        #expect(saved.originalScreenVideoURL == nil)
        #expect(saved.originalTranscriptData == nil)
        #expect(saved.originalRetranscriptData == nil)
        #expect(saved.trimEnd == nil)
        #expect(saved.mixdownURL == f.audioURL.path)
        #expect(saved.screenVideoURL == (video ? f.videoURL.path : nil))
        // Finalization normally removes the raw WAVs; migration does not need them.
        #expect(!FileManager.default.fileExists(atPath: saved.micAudioURL))
    }

    @Test(arguments: ["audio", "video"])
    func aMissingRequiredFileLeavesTheSessionUntouched(missing: String) async throws {
        let f = try TrimMigrationFixture(video: true)
        try FileManager.default.removeItem(at: missing == "audio" ? f.originalAudioURL : f.originalVideoURL)
        let disk = try f.disk(), records = try f.records()
        await f.reconcile()
        try f.reopen()
        #expect(try f.disk() == disk)
        #expect(try f.records() == records)
        #expect(try f.target().originalMixdownURL == f.originalAudioURL.path)
    }

    @Test
    func aTrimWithoutScreenVideoBackupDoesNotRequireOne() async throws {
        let f = try TrimMigrationFixture(video: false)
        try Data("unrelated".utf8).write(to: f.videoURL)
        await f.reconcile()
        #expect(try f.target().spliceGroupID != nil)
    }

    @Test
    func migrationIsIdempotent() async throws {
        let f = try TrimMigrationFixture(video: true)
        await f.reconcile()
        try f.reopen()
        let disk = try f.disk(), records = try f.records()
        await f.reconcile()
        try f.reopen()
        #expect(try f.disk() == disk)
        #expect(try f.records() == records)
    }

    @Test(arguments: [false, true])
    func aMigratedSessionRestoresToItsPreTrimState(video: Bool) async throws {
        let f = try TrimMigrationFixture(video: video)
        await f.reconcile()
        let session = try f.target()
        let group = try SpliceService.groupFolder(#require(session.spliceGroupID), workspace: f.workspace)
        let result = try await f.service().restore(session: session, workspace: f.workspace, context: f.context, coordinator: f.coordinator!)
        await f.coordinator!.waitUntilIdle()
        #expect(result == SpliceService.RestoreResult())
        try f.expectPreTrimState(video: video)
        #expect(!FileManager.default.fileExists(atPath: group.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.workspace.rootURL.path).allSatisfy { !$0.hasPrefix("_") })
    }

    @Test
    func aHeldTrimmedSnapshotMigratesAfterRecoveryAtTheRecoveredPath() async throws {
        let f = try TrimMigrationFixture(video: true)
        let coordinator = f.makeCoordinator()
        f.coordinator = coordinator
        await coordinator.activate(f.workspace, context: f.context)
        #expect(await coordinator.delete(try f.target(), context: f.context, undoManager: nil) == .deleted)
        await f.reconcile()
        let held = await coordinator.heldSessions()
        #expect(held.map(\.sessionID) == [f.targetID])
        #expect(held.first?.spliceGroupID == nil)
        #expect(!FileManager.default.fileExists(atPath: f.folder.path))

        #expect(await coordinator.restoreHeld(f.targetID, context: f.context))
        try f.reopen()
        let session = try f.target()
        let group = try SpliceService.groupFolder(#require(session.spliceGroupID), workspace: f.workspace)
        #expect(try Data(contentsOf: group.appendingPathComponent("recording.m4a")) == TrimMigrationFixture.originalAudio)
        #expect(try Data(contentsOf: group.appendingPathComponent("screen.mov")) == TrimMigrationFixture.originalVideo)
        #expect(!FileManager.default.fileExists(atPath: f.originalAudioURL.path))
        #expect(session.duration == 60)
        #expect(session.originalMixdownURL == nil && session.trimEnd == nil)

        await f.reconcile()
        _ = try await f.service().restore(session: f.target(), workspace: f.workspace, context: f.context, coordinator: f.coordinator!)
        try f.expectPreTrimState(video: true)
    }

    @Test(arguments: Array(1...6))
    func anInterruptedMigrationIsResolvedByTheNextReconciliation(step: Int) async throws {
        let f = try TrimMigrationFixture(video: true)
        let stop = MigrationStop(step)
        await f.reconcile(files: stop.files())
        #expect(stop.stopped)
        try f.reopen()
        await f.reconcile()
        try f.reopen()
        try f.expectMigrated()
        let disk = try f.disk(), records = try f.records()
        await f.reconcile()
        #expect(try f.disk() == disk)
        #expect(try f.records() == records)
    }

    @Test(arguments: ["audioMove", "videoMove", "manifest", "save"])
    func aFailedMigrationRollsBackAndTheNextReconciliationRetries(stage: String) async throws {
        let f = try TrimMigrationFixture(video: true)
        let disk = try f.disk(), records = try f.records()
        var files = SpliceFileOperations()
        let move = files.move, write = files.write
        files.move = { source, destination in
            try move(source, destination)
            if (stage == "audioMove" && destination.lastPathComponent == "recording.m4a")
                || (stage == "videoMove" && destination.lastPathComponent == "screen.mov") {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        files.write = { data, url in
            try write(data, url)
            if stage == "manifest", url.lastPathComponent == SpliceManifest.fileName { throw CocoaError(.fileWriteUnknown) }
        }
        await f.reconcile(files: files, save: { context in
            if stage == "save" { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        #expect(try f.disk() == disk)
        #expect(try f.records() == records)
        try f.reopen()
        #expect(try f.records() == records)
        await f.reconcile()
        try f.expectMigrated()
    }
}

@MainActor
private final class MigrationStop {
    let step: Int
    var count = 0
    var armed = false
    var stopped = false
    init(_ step: Int) { self.step = step }
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
        files.checkpoint = { _ in try self.hit() }
        return files
    }
}

@MainActor
final class TrimMigrationFixture {
    static let trimmedAudio = Data("trimmed audio".utf8)
    static let originalAudio = Data("original audio".utf8)
    static let trimmedVideo = Data("trimmed video".utf8)
    static let originalVideo = Data("original video".utf8)
    static let removedPhrase = "phrase after the cut"

    let root: URL
    let workspace: Workspace
    let folder: URL
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let targetID: UUID
    let fullTranscriptData: Data?
    let fullRetranscriptData: Data?
    let trimmedTranscriptData: Data?
    let trimmedRetranscriptData: Data?
    var container: ModelContainer?
    var context: ModelContext!
    var coordinator: SessionDeletionCoordinator?
    var audioURL: URL { folder.appendingPathComponent("recording.m4a") }
    var videoURL: URL { folder.appendingPathComponent("screen.mov") }
    var originalAudioURL: URL { folder.appendingPathComponent("recording-original.m4a") }
    var originalVideoURL: URL { folder.appendingPathComponent("screen-original.mov") }

    /// A session as the previous build's trim left it at 60 of 120 seconds.
    init(video: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        workspace = Workspace(rootURL: root.appendingPathComponent("workspace", isDirectory: true))
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        folder = try RecordingFileLayout.createRecordingFolder(in: workspace, createdAt: start)
        let container = try Self.openStore(at: root)
        let context = ModelContext(container)
        let session = RecordingSession(
            createdAt: start, duration: 120, micAudioURL: folder.appendingPathComponent("mic.wav").path,
            screenVideoURL: video ? folder.appendingPathComponent("screen.mov").path : nil,
            mixdownURL: folder.appendingPathComponent("recording.m4a").path, title: "Trimmed", status: .done
        )
        targetID = session.id
        context.insert(session)
        let full = [("kept words", Float(10), Float(20)), (Self.removedPhrase, 65, 70)].map {
            TranscriptSegment(speakerId: "S1", text: $0.0, startTime: $0.1, endTime: $0.2)
        }
        let speakers = [TranscriptSpeaker(id: "S1", label: "Speaker", colorHex: "112233")]
        session.transcript = Transcript(fullText: Transcript.fullText(joining: full), segments: full, speakers: speakers)
        let fullSecond = full.map { TranscriptSegment(speakerId: $0.speakerId, text: $0.text.uppercased(), startTime: $0.startTime, endTime: $0.endTime) }
        session.retranscript = Transcript(fullText: Transcript.fullText(joining: fullSecond), segments: fullSecond, speakers: speakers)
        fullTranscriptData = session.transcriptData
        fullRetranscriptData = session.retranscriptData
        session.transcript = Transcript(fullText: "kept words", segments: [full[0]], speakers: speakers)
        session.retranscript = Transcript(fullText: "KEPT WORDS", segments: [fullSecond[0]], speakers: speakers)
        trimmedTranscriptData = session.transcriptData
        trimmedRetranscriptData = session.retranscriptData
        session.originalTranscriptData = fullTranscriptData
        session.originalRetranscriptData = fullRetranscriptData
        session.originalMixdownURL = originalAudioURL.path
        session.originalScreenVideoURL = video ? originalVideoURL.path : nil
        session.trimEnd = 60
        try Self.trimmedAudio.write(to: audioURL)
        try Self.originalAudio.write(to: originalAudioURL)
        if video {
            try Self.trimmedVideo.write(to: videoURL)
            try Self.originalVideo.write(to: originalVideoURL)
        }
        try writeTranscriptMarkdown(for: session, writeEmpty: true)
        try context.save()
        try reopen()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static func openStore(at root: URL) throws -> ModelContainer {
        try ModelContainer(for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(url: root.appendingPathComponent("store.sqlite")))
    }

    func reopen() throws {
        coordinator = nil
        context = nil
        container = nil
        container = try Self.openStore(at: root)
        context = ModelContext(container!)
        context.autosaveEnabled = false
    }

    func target() throws -> RecordingSession { try #require(try RecordingSession.fetch(id: targetID, in: context)) }

    func makeCoordinator() -> SessionDeletionCoordinator {
        SessionDeletionCoordinator(workspaceService: ReconciliationWorkspace(workspace: workspace), announce: { _ in },
            startAccess: { _ in false }, stopAccess: { _ in }, scheduleExpiry: { _, _ in AnyCancellable {} })
    }

    func service(files: SpliceFileOperations = SpliceFileOperations(),
                 save: @escaping (ModelContext) throws -> Void = { try $0.save() }) -> SpliceService {
        SpliceService(files: files, capacityProvider: { _ in .max }, saveContext: save, reconciliationCoordinator: coordinator)
    }

    func reconcile(files: SpliceFileOperations = SpliceFileOperations(),
                   save: @escaping (ModelContext) throws -> Void = { try $0.save() }) async {
        if coordinator == nil {
            coordinator = makeCoordinator()
            await coordinator!.activate(workspace, context: context)
        }
        await service(files: files, save: save).reconcile(workspace: workspace, context: context)
        await coordinator!.waitUntilIdle()
    }

    func records() throws -> [RecordingSessionRecord] {
        try context.fetch(FetchDescriptor<RecordingSession>()).sorted { $0.id.uuidString < $1.id.uuidString }.map(RecordingSessionRecord.init)
    }

    func expectMigrated() throws {
        let session = try target()
        let group = try SpliceService.groupFolder(#require(session.spliceGroupID), workspace: workspace)
        #expect(try Data(contentsOf: group.appendingPathComponent("recording.m4a")) == Self.originalAudio)
        #expect(try Data(contentsOf: group.appendingPathComponent("screen.mov")) == Self.originalVideo)
        #expect(FileManager.default.fileExists(atPath: group.appendingPathComponent(SpliceManifest.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: group.appendingPathComponent(SpliceJournal.fileName).path))
        #expect(try Data(contentsOf: audioURL) == Self.trimmedAudio)
        #expect(try Data(contentsOf: videoURL) == Self.trimmedVideo)
        #expect(!FileManager.default.fileExists(atPath: originalAudioURL.path))
        #expect(!FileManager.default.fileExists(atPath: originalVideoURL.path))
        #expect(session.duration == 60)
        #expect(session.originalMixdownURL == nil && session.originalScreenVideoURL == nil && session.trimEnd == nil)
        #expect(session.originalTranscriptData == nil && session.originalRetranscriptData == nil)
        let groups = try FileManager.default.contentsOfDirectory(atPath: workspace.rootURL.appendingPathComponent("splice").path)
        #expect(groups == [group.lastPathComponent])
    }

    func expectPreTrimState(video: Bool) throws {
        let session = try target()
        #expect(session.spliceGroupID == nil)
        #expect(session.duration == 120)
        #expect(session.createdAt == start)
        #expect(session.title == "Trimmed")
        #expect(session.transcriptData == fullTranscriptData)
        #expect(session.retranscriptData == fullRetranscriptData)
        #expect(session.searchableText?.contains(Self.removedPhrase.uppercased()) == true)
        #expect(session.originalMixdownURL == nil && session.trimEnd == nil)
        #expect(try Data(contentsOf: audioURL) == Self.originalAudio)
        #expect(session.mixdownURL == audioURL.path)
        if video {
            #expect(try Data(contentsOf: videoURL) == Self.originalVideo)
            #expect(session.screenVideoURL == videoURL.path)
        } else {
            #expect(session.screenVideoURL == nil)
        }
        let markdown = try String(contentsOf: transcriptMarkdownURL(for: session), encoding: .utf8)
        #expect(markdown.contains(Self.removedPhrase.uppercased()))
    }

    func disk() throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: workspace.rootURL, includingPropertiesForKeys: [.isRegularFileKey]))
        var bytes: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            bytes[String(url.path.dropFirst(workspace.rootURL.path.count))] = try Data(contentsOf: url)
        }
        return bytes
    }
}
