import Combine
import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
struct SpliceRestoreTests {
    @Test(arguments: [0, 2])
    func restoresFromFirstOrLaterPartAndHoldsEveryOtherMember(targetIndex: Int) async throws {
        let f = try await RestoreFixture()
        let target = try f.part(targetIndex)
        let before = RecordingSessionRecord(target)
        let result = try await f.service().restore(session: target, workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        await f.coordinator.waitUntilIdle()
        #expect(result == SpliceService.RestoreResult())
        #expect(target.id == before.id)
        #expect(target.tags.map(\.id) == before.tagIDs)
        #expect(target.aiTransformationsData == before.aiTransformationsData)
        #expect(target.transcriptSegments.map(\.id) == before.transcriptSegments.map(\.id))
        #expect(target.spliceGroupID == nil)
        #expect(target.status == .done)
        #expect(target.duration == f.original.duration)
        #expect(target.createdAt == f.original.createdAt)
        #expect(target.title == f.original.title)
        #expect(target.transcriptData == f.original.transcriptData)
        #expect(target.retranscriptData == f.original.retranscriptData)
        #expect(target.searchableText == target.retranscript?.fullText)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.mixdownURL!)) == RestoreFixture.originalAudio)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.screenVideoURL!)) == RestoreFixture.originalVideo)
        let markdown = try String(contentsOf: transcriptMarkdownURL(for: target), encoding: .utf8)
        #expect(markdown.contains("ONE") && markdown.contains("FOUR"))
        #expect(try f.context.fetch(FetchDescriptor<RecordingSession>()).map(\.id) == [target.id])
        let held = await f.coordinator.heldSessions()
        #expect(Set(held.map(\.sessionID)) == Set(f.partIDs.filter { $0 != target.id }))
        #expect(held.allSatisfy { $0.deletedAt == f.time })
        #expect(f.delays.count == 3)
        #expect(f.delays.allSatisfy { $0 == SessionDeletionCoordinator.holdDuration })
        #expect(!f.windowUndo.canUndo && !f.windowUndo.canRedo)
        // Holding the other parts is one step of the restore, so none of them is announced.
        #expect(f.announcements.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.group.path))
        #expect(try f.stagingFolders().isEmpty)
        #expect(f.deleteSaveCount == 3)
    }

    @Test
    func restoredSpeakerNamesComeFromTheCurrentManifest() async throws {
        let f = try await RestoreFixture(video: false)
        let manifestURL = f.group.appendingPathComponent(SpliceManifest.fileName)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        for key in ["transcriptData", "retranscriptData"] {
            let encoded = try #require(object[key] as? String)
            let data = try #require(Data(base64Encoded: encoded))
            var transcript = try JSONDecoder().decode(Transcript.self, from: data)
            let speaker = transcript.speakers[0]
            transcript.speakers[0] = TranscriptSpeaker(id: speaker.id, label: "Renamed in the group", colorHex: speaker.colorHex)
            object[key] = try JSONEncoder().encode(transcript).base64EncodedString()
        }
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        let target = try f.part(2)
        _ = try await f.service().restore(session: target, workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        #expect(target.transcript?.speakers.first?.label == "Renamed in the group")
        #expect(target.retranscript?.speakers.first?.label == "Renamed in the group")
        #expect(target.screenVideoURL == nil)
        #expect(try String(contentsOf: transcriptMarkdownURL(for: target), encoding: .utf8).contains("Renamed in the group"))
    }

    @Test(arguments: ["workspace", "coordinatorWorkspace", "noGroup", "manifest", "corruptManifest", "originalAudio", "originalVideo", "recording", "converting", "transcribing", "retranscribing", "pendingMux", "failedMux", "reservation", "journal", "foreignMember", "foreignAudio"])
    func preconditionsRefuseWithoutChanges(reason: String) async throws {
        let f = try await RestoreFixture()
        let target = try f.part(1)
        var workspace = f.workspace
        let reservations = SpliceReservations()
        var expected = SpliceError.missingOriginal
        switch reason {
        case "workspace": workspace = Workspace(rootURL: f.workspace.rootURL.appendingPathComponent("other")); expected = .inactiveWorkspace
        case "coordinatorWorkspace": f.workspaceService.currentWorkspaceResult = nil; expected = .inactiveWorkspace
        case "noGroup": target.spliceGroupID = nil
        case "manifest": try FileManager.default.removeItem(at: f.group.appendingPathComponent(SpliceManifest.fileName))
        case "corruptManifest": try Data([0]).write(to: f.group.appendingPathComponent(SpliceManifest.fileName))
        case "originalAudio": try FileManager.default.removeItem(at: f.group.appendingPathComponent("recording.m4a"))
        case "originalVideo": try FileManager.default.removeItem(at: f.group.appendingPathComponent("screen.mov"))
        case "recording": try f.part(3).status = .recording; expected = .unfinishedRecording
        case "converting": try f.part(3).status = .converting; expected = .unfinishedRecording
        case "transcribing": try f.part(3).status = .transcribing; expected = .unfinishedRecording
        case "retranscribing": try f.part(3).status = .retranscribing; expected = .unfinishedRecording
        case "pendingMux": try f.part(3).screenMuxState = ScreenMuxState.pending.rawValue; expected = .unfinishedRecording
        case "failedMux": try f.part(3).screenMuxState = ScreenMuxState.failed.rawValue; expected = .unfinishedRecording
        case "reservation": try reservations.reserve(sessionID: UUID(), groupID: f.groupID); expected = .busy
        case "journal": try Data([0]).write(to: f.group.appendingPathComponent(SpliceJournal.fileName)); expected = .busy
        case "foreignMember": try f.part(3).micAudioURL = f.workspace.rootURL.appendingPathComponent("outside/mic.wav").path; expected = .inactiveWorkspace
        default: target.mixdownURL = f.group.appendingPathComponent("recording.m4a").path; expected = .inactiveWorkspace
        }
        try f.context.save()
        let bytes = try f.disk(), records = try f.records()
        await #expect(throws: expected) {
            _ = try await f.service(reservations: reservations).restore(session: target, workspace: workspace, context: f.context, coordinator: f.coordinator)
        }
        #expect(try f.disk() == bytes)
        #expect(try f.records() == records)
        #expect(f.deleteSaveCount == 0)
    }

    @Test(arguments: [1, 3, 4])
    func failedFileMoveReversesEvenAMoveThatThrewAfterMoving(failingMove: Int) async throws {
        let f = try await RestoreFixture()
        let bytes = try f.disk(), records = try f.records()
        var files = SpliceFileOperations()
        let move = files.move
        var count = 0
        files.move = { source, destination in
            count += 1
            // Each move has a recovery journal already on disk.
            let journal = try JSONDecoder().decode(SpliceJournal.self, from: Data(contentsOf: f.group.appendingPathComponent(SpliceJournal.fileName)))
            #expect(journal.operation == "restore")
            try move(source, destination)
            if count == failingMove { throw CocoaError(.fileWriteUnknown) }
        }
        await #expect(throws: CocoaError.self) {
            _ = try await f.service(files: files).restore(session: f.part(1), workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        }
        #expect(try f.disk() == bytes)
        #expect(try f.records() == records)
        #expect(f.deleteSaveCount == 0)
    }

    @Test(arguments: ["save", "markdown"])
    func failedTargetSaveOrMarkdownRestoresTheTargetBeforeAnySiblingIsTouched(stage: String) async throws {
        let f = try await RestoreFixture()
        let bytes = try f.disk(), records = try f.records()
        let target = try f.part(2)
        var files = SpliceFileOperations()
        let write = files.write
        var failed = false
        files.write = { data, url in
            try write(data, url)
            if stage == "markdown", url == transcriptMarkdownURL(for: target), !failed {
                failed = true
                throw CocoaError(.fileWriteUnknown)
            }
        }
        await #expect(throws: CocoaError.self) {
            _ = try await f.service(files: files, save: { context in
                if stage == "save" { throw CocoaError(.fileWriteUnknown) }
                try context.save()
            }).restore(session: target, workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        }
        #expect(try f.disk() == bytes)
        #expect(try f.records() == records)
        #expect(f.deleteSaveCount == 0)
        #expect(await f.coordinator.heldSessions().isEmpty)
    }

    @Test(arguments: [1, 3])
    func failedFirstOrLaterMemberDeleteLeavesItStandaloneAndContinues(failingDelete: Int) async throws {
        let f = try await RestoreFixture()
        let target = try f.part(1)
        let siblings = f.partIDs.filter { $0 != target.id }
        let failedID = siblings[failingDelete - 1]
        let failedBefore = RecordingSessionRecord(try #require(try RecordingSession.fetch(id: failedID, in: f.context)))
        f.beforeDeletionSave = { _, count in
            let saved = try #require(try RecordingSession.fetch(id: target.id, in: ModelContext(f.container)))
            #expect(saved.spliceGroupID == nil)
            #expect(saved.duration == f.original.duration)
            if count == failingDelete { throw CocoaError(.fileWriteUnknown) }
        }
        let result = try await f.service().restore(session: target, workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        #expect(result.failedSessionIDs == [failedID])
        #expect(!result.requiresReconciliation)
        let remaining = try #require(try RecordingSession.fetch(id: failedID, in: f.context))
        #expect(remaining.spliceGroupID == nil)
        #expect(remaining.title == failedBefore.title)
        #expect(remaining.duration == failedBefore.duration)
        #expect(remaining.transcriptData == failedBefore.transcriptData)
        #expect(remaining.aiTransformationsData == failedBefore.aiTransformationsData)
        #expect(FileManager.default.fileExists(atPath: remaining.mixdownURL!))
        #expect(try f.context.fetch(FetchDescriptor<RecordingSession>()).count == 2)
        #expect(await f.coordinator.heldSessions().count == 2)
        #expect(!FileManager.default.fileExists(atPath: f.group.path))
        #expect(f.deleteSaveCount == 3)
        #expect(!f.windowUndo.canUndo)
    }

    @Test
    func failedMemberFolderMoveIsReportedWithoutOverwritingTheOccupiedHold() async throws {
        let f = try await RestoreFixture()
        let failed = try f.part(1)
        let held = HoldingFolder(workspace: f.workspace).heldFolder(for: failed.id)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        let sentinel = held.appendingPathComponent("keep")
        try Data("occupied".utf8).write(to: sentinel)
        let result = try await f.service().restore(session: f.part(0), workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        #expect(result.failedSessionIDs == [failed.id])
        #expect(failed.spliceGroupID == nil)
        #expect(try Data(contentsOf: sentinel) == Data("occupied".utf8))
        #expect(FileManager.default.fileExists(atPath: failed.mixdownURL!))
        #expect(!FileManager.default.fileExists(atPath: f.group.path))
    }

    @Test
    func previouslyHeldAndNewlyHeldPartsRecoverAsStandaloneAfterRestore() async throws {
        let f = try await RestoreFixture()
        let earlierHeld = f.partIDs[3]
        #expect(await f.coordinator.delete(try f.part(3), context: f.context, undoManager: f.windowUndo) == .deleted)
        let target = try f.part(2)
        _ = try await f.service().restore(session: target, workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: target.mixdownURL!))
        for id in [earlierHeld, f.partIDs[0]] {
            #expect(await f.coordinator.restoreHeld(id, context: f.context))
            let recovered = try #require(try RecordingSession.fetch(id: id, in: f.context))
            #expect(recovered.spliceGroupID == nil)
            #expect(recovered.duration < target.duration)
            #expect(FileManager.default.fileExists(atPath: recovered.mixdownURL!))
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.mixdownURL!)) == originalBytes)
        #expect(!f.windowUndo.canRedo)
        #expect(!f.windowUndo.canUndo)
    }

    @Test
    func heldPartRejoinsWhenItsGroupStillExists() async throws {
        let f = try await RestoreFixture()
        let id = f.partIDs[1]
        #expect(await f.coordinator.delete(try f.part(1), context: f.context, undoManager: nil) == .deleted)
        #expect(await f.coordinator.restoreHeld(id, context: f.context))
        #expect(try RecordingSession.fetch(id: id, in: f.context)?.spliceGroupID == f.groupID)
    }

    @Test(arguments: ["missingMedia", "corruptTranscript"])
    func restoreCanRepairADamagedPartWhenTheOriginalIsReadable(damage: String) async throws {
        let f = try await RestoreFixture()
        let target = try f.part(2)
        if damage == "missingMedia" {
            try FileManager.default.removeItem(atPath: target.mixdownURL!)
            try FileManager.default.removeItem(atPath: target.screenVideoURL!)
        } else {
            target.transcriptData = Data([0])
            target.retranscriptData = nil
            target.status = .error("damaged part")
        }
        _ = try await f.service().restore(session: target, workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        #expect(target.status == .done)
        #expect(target.transcriptData == f.original.transcriptData)
        #expect(target.retranscriptData == f.original.retranscriptData)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.mixdownURL!)) == RestoreFixture.originalAudio)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.screenVideoURL!)) == RestoreFixture.originalVideo)
    }

    @Test
    func targetSaveFailurePreservesPreviouslyPendingUnrelatedChanges() async throws {
        let f = try await RestoreFixture()
        let target = try f.part(1)
        let before = RecordingSessionRecord(target)
        let unrelated = RecordingSession(duration: 1, micAudioURL: "unrelated", title: "Pending change")
        f.context.insert(unrelated)
        await #expect(throws: CocoaError.self) {
            _ = try await f.service(save: { context in
                if target.spliceGroupID == nil { throw CocoaError(.fileWriteUnknown) }
                try context.save()
            }).restore(session: target, workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        }
        #expect(RecordingSessionRecord(target) == before)
        let fresh = ModelContext(f.container)
        #expect(try RecordingSession.fetch(id: unrelated.id, in: fresh)?.title == "Pending change")
        #expect(f.deleteSaveCount == 0)
    }

    @Test
    func detachmentSaveFailureKeepsTheCommittedTargetAndRecoveryJournal() async throws {
        let f = try await RestoreFixture()
        let target = try f.part(0)
        f.beforeDeletionSave = { _, count in if count == 1 { throw CocoaError(.fileWriteUnknown) } }
        var saves = 0
        let result = try await f.service(save: { context in
            saves += 1
            if saves == 2 { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }).restore(session: target, workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        #expect(result.failedSessionIDs == [f.partIDs[1]])
        #expect(result.requiresReconciliation)
        #expect(target.spliceGroupID == nil)
        #expect(target.duration == f.original.duration)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target.mixdownURL!)) == RestoreFixture.originalAudio)
        #expect(FileManager.default.fileExists(atPath: f.group.appendingPathComponent(SpliceJournal.fileName).path))
        #expect(try RecordingSession.fetch(id: f.partIDs[1], in: f.context)?.spliceGroupID == f.groupID)
    }

    @Test
    func rollbackFailureKeepsTheJournalAndBackups() async throws {
        let f = try await RestoreFixture()
        let target = try f.part(1)
        var files = SpliceFileOperations()
        let move = files.move
        files.move = { source, destination in
            if source.lastPathComponent.hasPrefix("before-") { throw CocoaError(.fileWriteUnknown) }
            try move(source, destination)
        }
        await #expect(throws: CocoaError.self) {
            _ = try await f.service(files: files, save: { _ in throw CocoaError(.fileWriteUnknown) })
                .restore(session: target, workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        }
        let journal = try JSONDecoder().decode(SpliceJournal.self, from: Data(contentsOf: f.group.appendingPathComponent(SpliceJournal.fileName)))
        #expect(journal.operation == "restore")
        #expect(Set(journal.restoreMemberIDs ?? []) == Set(f.partIDs.filter { $0 != target.id }))
        #expect(journal.originalRecord.spliceGroupID == f.groupID)
        #expect(FileManager.default.fileExists(atPath: journal.stagingFolder.path))
        #expect(try Data(contentsOf: f.group.appendingPathComponent("recording.m4a")) == RestoreFixture.originalAudio)
        #expect(try f.context.fetch(FetchDescriptor<RecordingSession>()).count == 4)
        #expect(f.deleteSaveCount == 0)
    }

    @Test(arguments: [false, true])
    func groupPathCheckRefusesSymlinksToOtherFolders(sibling: Bool) async throws {
        let f = try await RestoreFixture()
        let target = try f.part(0)
        let other = sibling ? f.group.deletingLastPathComponent().appendingPathComponent(UUID().uuidString) : f.workspace.rootURL.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: f.group, to: other)
        try FileManager.default.createSymbolicLink(at: f.group, withDestinationURL: other)
        let bytes = try f.disk(), records = try f.records()
        await #expect(throws: SpliceError.inactiveWorkspace) {
            _ = try await f.service().restore(session: target, workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        }
        #expect(try f.disk() == bytes)
        #expect(try f.records() == records)
    }

    @Test
    func heldPartsUseTheCoordinatorsClockAndExpiryScheduler() async throws {
        let f = try await RestoreFixture()
        _ = try await f.service().restore(session: f.part(0), workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        f.time.addTimeInterval(SessionDeletionCoordinator.holdDuration)
        for action in f.expiryActions { action() }
        await f.coordinator.waitUntilIdle()
        #expect(await f.coordinator.heldSessions().isEmpty)
        #expect(try f.context.fetch(FetchDescriptor<RecordingSession>()).count == 1)
    }

    @Test
    func committedRestoreRetainsItsJournalWhenGroupCleanupFails() async throws {
        let f = try await RestoreFixture()
        var files = SpliceFileOperations()
        let remove = files.remove
        files.remove = { url in
            if url.path == f.group.path { throw CocoaError(.fileWriteUnknown) }
            try remove(url)
        }
        let target = try f.part(1)
        let result = try await f.service(files: files).restore(session: target, workspace: f.workspace, context: f.context, coordinator: f.coordinator)
        #expect(result.requiresReconciliation)
        #expect(result.failedSessionIDs.isEmpty)
        #expect(target.spliceGroupID == nil)
        #expect(target.duration == f.original.duration)
        #expect(FileManager.default.fileExists(atPath: f.group.appendingPathComponent(SpliceJournal.fileName).path))
        #expect(await f.coordinator.heldSessions().count == 3)
    }

    @Test
    func restoreAvailabilityChecksTheWorkspaceAndEveryGroupMembersReadiness() {
        func availability(group: Bool = true, workspace: Bool = true, mux: Bool = false,
                          busy: Bool = false, status: RecordingStatus = .done) -> SessionCommandAvailability {
            SessionCommandAvailability(selection: .recording(status, isTrimmed: false), isRecordingRunning: false,
                isTranscriptShown: false, hasLoadedAudio: false, hasFindTarget: true, isSelectionInActiveWorkspace: workspace,
                hasPendingScreenMux: mux, hasSpliceGroup: group, hasBusySpliceMember: busy)
        }
        #expect(availability().isEnabled(.restoreOriginal))
        #expect(availability(status: .error("failed")).isEnabled(.restoreOriginal))
        #expect(availability(status: .recorded).isEnabled(.restoreOriginal))
        #expect(!availability(group: false).isEnabled(.restoreOriginal))
        #expect(!availability(workspace: false).isEnabled(.restoreOriginal))
        #expect(!availability(mux: true).isEnabled(.restoreOriginal))
        #expect(!availability(busy: true).isEnabled(.restoreOriginal))
        for status: RecordingStatus in [.recording, .converting, .transcribing, .retranscribing] {
            #expect(!availability(status: status).isEnabled(.restoreOriginal))
        }
    }

    @Test
    func partialRestoreUsesTheApprovedSingularAndPluralCopy() {
        #expect(SpliceCopy.restorePartialMessage(1) == "1 part could not be moved to Pending deletions and is still in your list.")
        #expect(SpliceCopy.restorePartialMessage(3) == "3 parts could not be moved to Pending deletions and are still in your list.")
    }
}

@MainActor
private final class RestoreFixture {
    static let originalAudio = Data("original full audio".utf8)
    static let originalVideo = Data("original full video".utf8)
    let workspace: Workspace
    let workspaceService = MockWorkspaceService()
    let container: ModelContainer
    let context: ModelContext
    let original: RecordingSessionRecord
    var partIDs: [UUID] = []
    var groupID = UUID()
    var time = Date(timeIntervalSince1970: 1_800_000_000)
    var deleteSaveCount = 0
    var beforeDeletionSave: ((ModelContext, Int) throws -> Void)?
    var delays: [TimeInterval] = []
    var announcements: [String] = []
    var expiryActions: [@MainActor () -> Void] = []
    let windowUndo = UndoManager.forTests()
    var group: URL { workspace.rootURL.appendingPathComponent("splice").appendingPathComponent(groupID.uuidString) }

    lazy var coordinator = SessionDeletionCoordinator(
        workspaceService: workspaceService,
        saveContext: { [unowned self] context in
            deleteSaveCount += 1
            try beforeDeletionSave?(context, deleteSaveCount)
            try context.save()
        },
        now: { [unowned self] in time }, announce: { [unowned self] in announcements.append($0) }, startAccess: { _ in false }, stopAccess: { _ in },
        scheduleExpiry: { [unowned self] delay, action in
            delays.append(delay)
            expiryActions.append(action)
            return AnyCancellable {}
        }
    )

    init(video: Bool = true) async throws {
        workspace = Workspace(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
        workspaceService.currentWorkspaceResult = workspace
        let folder = try RecordingFileLayout.createRecordingFolder(in: workspace, createdAt: time)
        container = try ModelContainer(for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        context.autosaveEnabled = false
        let session = RecordingSession(createdAt: time, duration: 80, micAudioURL: folder.appendingPathComponent("mic.wav").path,
            screenVideoURL: video ? folder.appendingPathComponent("screen.mov").path : nil,
            mixdownURL: folder.appendingPathComponent("recording.m4a").path, title: "Full original", status: .done)
        let segments = ["one", "two", "three", "four"].enumerated().map {
            TranscriptSegment(speakerId: "A", text: $0.element, startTime: Float($0.offset * 20), endTime: Float($0.offset * 20 + 10))
        }
        let speakers = [TranscriptSpeaker(id: "A", label: "Alice", colorHex: "112233")]
        session.transcript = Transcript(fullText: Transcript.fullText(joining: segments), segments: segments, speakers: speakers)
        let second = segments.map { TranscriptSegment(speakerId: $0.speakerId, text: $0.text.uppercased(), startTime: $0.startTime, endTime: $0.endTime) }
        session.retranscript = Transcript(fullText: Transcript.fullText(joining: second), segments: second, speakers: speakers)
        let tag = RecordingTag(name: "Work", colorHex: "112233")
        context.insert(tag); context.insert(session)
        session.tags = [tag]
        try Self.originalAudio.write(to: folder.appendingPathComponent("recording.m4a"))
        if video { try Self.originalVideo.write(to: folder.appendingPathComponent("screen.mov")) }
        try context.save()
        original = RecordingSessionRecord(session)
        let plan = SplicePlan(cuts: [15, 35, 55], parts: (1...4).map { .init(title: "Part \($0)") },
                              transcriptFingerprint: SplicePlan.fingerprint(transcriptData: session.transcriptData, retranscriptData: session.retranscriptData))
        let service = SpliceService(capacityProvider: { _ in .max }, export: { source, destination, start, end in
            try (Data("\(start)..\(end):".utf8) + Data(contentsOf: source)).write(to: destination)
        })
        let parts = try await service.splice(session: session, plan: plan, workspace: workspace, context: context)
        partIDs = parts.map(\.id)
        groupID = try #require(session.spliceGroupID)
        for (index, part) in parts.enumerated() {
            part.aiTransformations = [AITransformation(promptName: "Summary", modelID: "test", resultText: "Part \(index)")]
            part.transcriptSegments = [RecordingTranscriptSegment(speakerId: "live", text: "Live row \(index)", startTime: 1, endTime: 2, audioSource: .mic)]
        }
        try context.save()
    }

    deinit { try? FileManager.default.removeItem(at: workspace.rootURL) }

    func part(_ index: Int) throws -> RecordingSession {
        try #require(try RecordingSession.fetch(id: partIDs[index], in: context))
    }

    func service(files: SpliceFileOperations = SpliceFileOperations(),
                 save: @escaping (ModelContext) throws -> Void = { try $0.save() },
                 reservations: SpliceReservations? = nil) -> SpliceService {
        SpliceService(files: files, saveContext: save, now: { [time] in time }, reservations: reservations)
    }

    func records() throws -> [RecordingSessionRecord] {
        try context.fetch(FetchDescriptor<RecordingSession>()).sorted { $0.id.uuidString < $1.id.uuidString }.map(RecordingSessionRecord.init)
    }

    func disk() throws -> [String: Data] {
        let root = workspace.rootURL
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var bytes: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            bytes[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return bytes
    }

    func stagingFolders() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workspace.rootURL.path).filter { $0.hasPrefix("_restore_") }
    }
}
