import AVFoundation
import Foundation
import OSLog
import SwiftData

@MainActor
final class SpliceService {
    typealias Export = (URL, URL, Double, Double) async throws -> Void
    private let files: SpliceFileOperations
    private let capacity: (URL) -> Int64?
    private let export: Export
    private let save: (ModelContext) throws -> Void
    private let now: () -> Date
    private let reservations: SpliceReservations
    private let membership: SpliceMembershipReader
    private let reconciliationCoordinator: SessionDeletionCoordinator?
    private let logger = Logger(subsystem: "Scriberman", category: "SpliceService")

    init(
        files: SpliceFileOperations = SpliceFileOperations(),
        capacityProvider: @escaping (URL) -> Int64? = {
            (try? $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        },
        export: Export? = nil,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() },
        now: @escaping () -> Date = { .now },
        reservations: SpliceReservations? = nil,
        membership: SpliceMembershipReader = SpliceMembershipReader(),
        reconciliationCoordinator: SessionDeletionCoordinator? = nil
    ) {
        self.files = files
        capacity = capacityProvider
        self.export = export ?? Self.exportTimeRange
        save = saveContext
        self.now = now
        self.reservations = reservations ?? .shared
        self.membership = membership
        self.reconciliationCoordinator = reconciliationCoordinator
    }

    /// Files are staged before the journal and moved only after it. No await occurs between
    /// installing those files and saving the store. A committed save is never rolled back because
    /// later cleanup failed: its journal remains for reconciliation instead.
    @discardableResult
    func splice(
        session: RecordingSession, plan: SplicePlan, workspace: Workspace, context: ModelContext
    ) async throws -> [RecordingSession] {
        let folder = URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
        guard isSessionFolder(folder, workspace: workspace), session.modelContext === context else {
            throw SpliceError.inactiveWorkspace
        }
        guard session.status == .done, session.screenMuxState == nil else { throw SpliceError.unfinishedRecording }
        guard !session.isTrimmed else { throw SpliceError.requiresTrimMigration }
        guard let path = session.mixdownURL,
              URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
              FileManager.default.isReadableFile(atPath: path) else { throw SpliceError.missingMixdown }
        guard session.displayedTranscript != nil else { throw SpliceError.missingTranscript }
        // A corrupt non-displayed pass must not be silently erased by slicing.
        let transcript = try decodePass(session.transcriptData)
        let retranscript = try decodePass(session.retranscriptData)
        try Self.validate(plan: plan, duration: session.duration, transcript: transcript, retranscript: retranscript,
                          transcriptData: session.transcriptData, retranscriptData: session.retranscriptData)
        let audio = URL(fileURLWithPath: path)
        let video = session.screenVideoURL.map { URL(fileURLWithPath: $0) }
        if let video {
            guard video.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
                  FileManager.default.isReadableFile(atPath: video.path) else { throw SpliceError.missingOriginal }
        }
        let groupID = session.spliceGroupID ?? UUID()
        guard !reservations.isReserved(sessionID: session.id, groupID: groupID) else { throw SpliceError.busy }
        let group = try Self.groupFolder(groupID, workspace: workspace)
        let createsGroup = session.spliceGroupID == nil
        let manifest: SpliceManifest
        if createsGroup {
            guard !exists(group) else { throw SpliceError.missingOriginal }
            manifest = SpliceManifest(session: session)
        } else {
            manifest = try readManifest(in: group)
        }
        guard !exists(group.appendingPathComponent(SpliceJournal.fileName)) else { throw SpliceError.busy }
        let memberIDs = try Set(groupMembers(groupID, context: context).map(\.id)).union([session.id])
        let reservation = try reservations.reserve(sessionIDs: memberIDs, groupID: groupID)
        defer { reservations.release(reservation) }
        if context.hasChanges { try save(context) }
        let before = RecordingSessionRecord(session)
        try checkDiskSpace([audio, video].compactMap { $0 }, workspace: workspace)

        let staging = workspace.rootURL.appendingPathComponent("_splice_" + UUID().uuidString, isDirectory: true)
        let markdown = transcriptMarkdownURL(for: session)
        let previousMarkdown = exists(markdown) ? try Data(contentsOf: markdown) : nil
        var newFolders: [URL] = []
        var madeGroup = false
        var journal: SpliceJournal?
        var modelsTouched = false
        let journalURL = group.appendingPathComponent(SpliceJournal.fileName)
        do {
            try files.createDirectory(staging, false)
            let boundaries = [0] + plan.cuts + [session.duration]
            let firstPass = transcript.map { Self.slice($0, cuts: plan.cuts, originSessionID: manifest.originalSessionID) }
            let secondPass = retranscript.map { Self.slice($0, cuts: plan.cuts, originSessionID: manifest.originalSessionID) }
            let kept = plan.parts.indices.filter { !plan.parts[$0].isDropped }
            var outputs: [Output] = []
            for (keptIndex, index) in kept.enumerated() {
                let output = Output(
                    id: keptIndex == 0 ? session.id : UUID(),
                    createdAt: session.createdAt.addingTimeInterval(boundaries[index]),
                    duration: boundaries[index + 1] - boundaries[index], title: plan.parts[index].title,
                    transcript: firstPass?[index], retranscript: secondPass?[index],
                    audio: staging.appendingPathComponent("\(index).m4a"),
                    video: video.map { _ in staging.appendingPathComponent("\(index).mov") }
                )
                try await export(audio, output.audio, boundaries[index], boundaries[index + 1])
                try Task.checkCancellation()
                if let video, let destination = output.video {
                    try await export(video, destination, boundaries[index], boundaries[index + 1])
                    try Task.checkCancellation()
                }
                outputs.append(output)
            }
            // Exports suspend. Refuse any source edit during that time and preserve unrelated
            // edits made in the shared context before starting the synchronous transaction.
            guard RecordingSessionRecord(session) == before else { throw SpliceError.stalePlan }
            if context.hasChanges { try save(context) }
            if createsGroup {
                try files.createDirectory(group, true)
                madeGroup = true
            }
            for output in outputs.dropFirst() {
                newFolders.append(try RecordingFileLayout.createRecordingFolder(
                    in: workspace, createdAt: output.createdAt, createDirectory: files.createDirectory
                ))
            }
            let folders = [folder] + newFolders
            var moves: [SpliceJournal.Move] = []
            for source in [audio, video].compactMap({ $0 }) {
                let backup = createsGroup
                    ? group.appendingPathComponent(source == audio ? "recording.m4a" : "screen.mov")
                    : staging.appendingPathComponent("before." + source.pathExtension)
                moves.append(.init(source: source, destination: backup))
            }
            for (index, output) in outputs.enumerated() {
                moves.append(.init(source: output.audio, destination: index == 0 ? audio : folders[index].appendingPathComponent("recording.m4a")))
                if let stagedVideo = output.video {
                    moves.append(.init(source: stagedVideo, destination: index == 0 ? video! : RecordingFileLayout.screenVideoURL(in: folders[index])))
                }
            }
            let preparedJournal = try SpliceJournal(
                groupID: groupID, createsGroup: createsGroup, originalRecord: before,
                moves: moves, newFolders: newFolders, stagingFolder: staging,
                markdownURL: markdown, previousMarkdown: previousMarkdown,
                results: outputs.map { try $0.result() }, startedAt: now()
            )
            journal = preparedJournal
            try files.write(JSONEncoder().encode(preparedJournal), journalURL)
            let originalCount = video == nil ? 1 : 2
            for move in moves.prefix(originalCount) { try files.move(move.source, move.destination) }
            if createsGroup {
                try files.write(JSONEncoder().encode(manifest), group.appendingPathComponent(SpliceManifest.fileName))
            }
            for move in moves.dropFirst(originalCount) { try files.move(move.source, move.destination) }
            var sessions: [RecordingSession] = []
            modelsTouched = true
            for (index, output) in outputs.enumerated() {
                let part: RecordingSession
                if index == 0 {
                    part = session
                } else {
                    part = RecordingSession(
                        id: output.id, createdAt: output.createdAt, duration: output.duration,
                        micAudioURL: RecordingFileLayout.recordingFileURLs(in: folders[index]).mic.path,
                        screenVideoURL: output.video.map { _ in RecordingFileLayout.screenVideoURL(in: folders[index]).path },
                        mixdownURL: folders[index].appendingPathComponent("recording.m4a").path,
                        title: output.title,
                        // The app name holds for the whole recording; capture flags describe
                        // stretches of it and are not copied.
                        capturedAppName: session.capturedAppName,
                        status: .done
                    )
                    context.insert(part)
                    part.tags = session.tags
                }
                part.createdAt = output.createdAt
                part.duration = output.duration
                part.title = output.title
                // Persist the exact pass bytes recorded in the journal. This model setter also
                // refreshes search text from the displayed pass.
                part.restoreTranscripts(
                    transcriptData: preparedJournal.results[index].transcriptData,
                    retranscriptData: preparedJournal.results[index].retranscriptData
                )
                part.spliceGroupID = groupID
                try writeTranscriptMarkdown(for: part, writeEmpty: true, writeData: files.write)
                sessions.append(part)
            }
            try save(context)
            try files.checkpoint(.storeSaved)
            // The save committed. Cleanup errors leave a journal; they do not report a failed
            // splice or reverse files belonging to the now-saved parts.
            do {
                try removeIfPresent(staging)
                try files.remove(journalURL)
            } catch {
                if error is SpliceFileOperations.Interruption { throw error }
                logger.error("Splice committed; cleanup remains in journal: \(error.localizedDescription, privacy: .public)")
            }
            return sessions
        } catch {
            if modelsTouched { context.rollback() }
            if error is SpliceFileOperations.Interruption { throw error }
            do {
                if let journal, exists(journalURL) {
                    try rollback(journal)
                    try markRollbackCompleted(journal, at: journalURL)
                }
                for folder in newFolders { try removeIfPresent(folder) }
                try removeIfPresent(staging)
                if madeGroup { try removeIfPresent(group) }
                else { try removeIfPresent(journalURL) }
            } catch {
                logger.error("Splice rollback failed; journal retained: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    struct RestoreResult: Equatable {
        var failedSessionIDs: [UUID] = []
        /// The target is committed; the journal still has post-save work for reconciliation.
        var requiresReconciliation = false
    }

    /// The target is one transaction. Only after it saves are siblings held, one at a time,
    /// through the deletion coordinator. A post-save failure never rolls the restored target back.
    func restore(
        session: RecordingSession, workspace: Workspace, context: ModelContext,
        coordinator: SessionDeletionCoordinator
    ) async throws -> RestoreResult {
        let folder = URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
        guard isSessionFolder(folder, workspace: workspace), session.modelContext === context, !session.isDeleted else {
            throw SpliceError.inactiveWorkspace
        }
        guard let groupID = session.spliceGroupID else { throw SpliceError.missingOriginal }
        guard !reservations.isReserved(sessionID: session.id, groupID: groupID) else { throw SpliceError.busy }
        let group = try Self.groupFolder(groupID, workspace: workspace)
        let journalURL = group.appendingPathComponent(SpliceJournal.fileName)
        guard !exists(journalURL) else { throw SpliceError.busy }
        let manifest = try readManifest(in: group)
        let members = try groupMembers(groupID, context: context)
        for member in members {
            guard isSessionFolder(URL(fileURLWithPath: member.micAudioURL).deletingLastPathComponent(), workspace: workspace) else {
                throw SpliceError.inactiveWorkspace
            }
            switch member.status {
            case .recording, .converting, .transcribing, .retranscribing: throw SpliceError.unfinishedRecording
            case .recorded, .done, .error: break
            }
            guard member.screenMuxState == nil else { throw SpliceError.unfinishedRecording }
        }
        let audio = session.mixdownURL.map { URL(fileURLWithPath: $0) } ?? folder.appendingPathComponent("recording.m4a")
        let currentVideo = session.screenVideoURL.map { URL(fileURLWithPath: $0) }
        for url in [audio, currentVideo].compactMap({ $0 }) {
            guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else {
                throw SpliceError.inactiveWorkspace
            }
        }
        let reservation = try reservations.reserve(sessionIDs: Set(members.map(\.id)), groupID: groupID)
        defer { reservations.release(reservation) }
        guard await coordinator.isActiveWorkspace(workspace) else { throw SpliceError.inactiveWorkspace }
        try Task.checkCancellation()
        if context.hasChanges { try save(context) }
        let staging = workspace.rootURL.appendingPathComponent("_restore_" + UUID().uuidString, isDirectory: true)
        let markdown = transcriptMarkdownURL(for: session)
        let previousMarkdown = exists(markdown) ? try Data(contentsOf: markdown) : nil
        var moves: [SpliceJournal.Move] = []
        for (index, url) in [audio, currentVideo].compactMap({ $0 }).enumerated() where exists(url) {
            moves.append(.init(source: url, destination: staging.appendingPathComponent("before-\(index)." + url.pathExtension)))
        }
        moves.append(.init(source: group.appendingPathComponent("recording.m4a"), destination: audio))
        let video = manifest.hasScreenVideo ? RecordingFileLayout.screenVideoURL(in: folder) : nil
        if let video { moves.append(.init(source: group.appendingPathComponent("screen.mov"), destination: video)) }
        let siblingIDs = members.filter { $0.id != session.id }.map(\.id)
        var journal = SpliceJournal(
            groupID: groupID, createsGroup: false, originalRecord: RecordingSessionRecord(session),
            moves: moves, newFolders: [], stagingFolder: staging, markdownURL: markdown,
            previousMarkdown: previousMarkdown,
            results: [.init(sessionID: session.id, createdAt: manifest.createdAt, duration: manifest.duration,
                            title: manifest.title, transcriptData: manifest.transcriptData, retranscriptData: manifest.retranscriptData)],
            startedAt: now()
        )
        journal.operation = "restore"
        journal.restoreMemberIDs = siblingIDs
        var modelsTouched = false
        do {
            try files.createDirectory(staging, false)
            try files.write(JSONEncoder().encode(journal), journalURL)
            for move in moves { try files.move(move.source, move.destination) }
            modelsTouched = true
            session.mixdownURL = audio.path
            session.screenVideoURL = video?.path
            session.createdAt = manifest.createdAt
            session.duration = manifest.duration
            session.title = manifest.title
            session.restoreTranscripts(transcriptData: manifest.transcriptData, retranscriptData: manifest.retranscriptData)
            session.spliceGroupID = nil
            session.status = .done
            try writeTranscriptMarkdown(for: session, writeEmpty: true, writeData: files.write)
            try save(context)
            try files.checkpoint(.storeSaved)
        } catch {
            if modelsTouched { context.rollback() }
            if error is SpliceFileOperations.Interruption { throw error }
            do {
                if exists(journalURL) {
                    try rollback(journal)
                    try markRollbackCompleted(journal, at: journalURL)
                }
                try removeIfPresent(staging)
                try removeIfPresent(journalURL)
            } catch {
                logger.error("Restore rollback failed; journal retained: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }

        return try await finishRestore(journal, workspace: workspace, context: context, coordinator: coordinator, reservation: reservation)
    }

    private func finishRestore(
        _ journal: SpliceJournal, workspace: Workspace, context: ModelContext, coordinator: SessionDeletionCoordinator,
        reservation: SpliceReservations.Reservation
    ) async throws -> RestoreResult {
        let groupID = journal.groupID
        let staging = journal.stagingFolder
        let siblingIDs = journal.restoreMemberIDs ?? []
        var result = RestoreResult()
        for id in siblingIDs {
            do {
                guard let member = try RecordingSession.fetch(id: id, in: context), member.spliceGroupID == groupID else { continue }
                let deletion = await coordinator.delete(member, context: context, undoManager: nil, announces: false, reservation: reservation)
                if deletion == .deleted {
                    try files.checkpoint(.memberProcessed(id))
                    continue
                }
                result.failedSessionIDs.append(id)
                // A failed hold may have rolled back the context. Resolve the member again.
                guard let remaining = try RecordingSession.fetch(id: id, in: context) else { continue }
                if context.hasChanges { try save(context) }
                remaining.spliceGroupID = nil
                do { try save(context) }
                catch { context.rollback(); throw error }
            } catch {
                if error is SpliceFileOperations.Interruption { throw error }
                if !result.failedSessionIDs.contains(id) { result.failedSessionIDs.append(id) }
                result.requiresReconciliation = true
                logger.error("Restore committed; member cleanup remains in journal: \(error.localizedDescription, privacy: .public)")
            }
            try files.checkpoint(.memberProcessed(id))
        }
        do {
            let remaining = try groupMembers(groupID, context: context)
            if !remaining.isEmpty {
                result.requiresReconciliation = true
                for member in remaining where !result.failedSessionIDs.contains(member.id) { result.failedSessionIDs.append(member.id) }
            }
            if !result.requiresReconciliation {
                try removeIfPresent(staging)
                // Validate again after the coordinator's awaits, before recursive removal.
                try files.remove(Self.groupFolder(groupID, workspace: workspace))
            }
        } catch {
            if error is SpliceFileOperations.Interruption { throw error }
            result.requiresReconciliation = true
            logger.error("Restore committed; group cleanup remains in journal: \(error.localizedDescription, privacy: .public)")
        }
        return result
    }

    private func markRollbackCompleted(_ journal: SpliceJournal, at url: URL) throws {
        var completed = journal
        completed.rollbackCompleted = true
        try files.write(JSONEncoder().encode(completed), url)
    }

    /// Called only after the workspace has been authorized. A fresh context reads the durable
    /// transaction outcome, rather than any pending edits in the caller's context.
    func reconcile(workspace: Workspace, context: ModelContext) async {
        await reconcileJournals(workspace: workspace, context: context)
        migrateTrimmedSessions(workspace: workspace, context: context)
        sweepUnusedGroups(workspace: workspace, context: context)
    }

    private func reconcileJournals(workspace: Workspace, context: ModelContext) async {
        let parent = workspace.rootURL.appendingPathComponent("splice", isDirectory: true)
        guard parent.resolvingSymlinksInPath().path == workspace.rootURL.resolvingSymlinksInPath()
            .appendingPathComponent("splice").path else { return }
        let entries: [URL]
        do { entries = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) }
        catch {
            if !Self.isMissingFile(error) { logger.error("Cannot read splice journals: \(error.localizedDescription, privacy: .public)") }
            return
        }
        let coordinator = reconciliationCoordinator ?? SessionDeletionCoordinator(
            workspaceService: ReconciliationWorkspace(workspace: workspace), spliceReservations: reservations
        )
        if reconciliationCoordinator == nil { await coordinator.activate(workspace, context: context) }
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            do {
                let group = try Self.groupFolder(id, workspace: workspace)
                let url = group.appendingPathComponent(SpliceJournal.fileName)
                guard exists(url) else { continue }
                guard url.resolvingSymlinksInPath().path == group.resolvingSymlinksInPath().appendingPathComponent(SpliceJournal.fileName).path else {
                    throw SpliceError.inactiveWorkspace
                }
                let journal = try JSONDecoder().decode(SpliceJournal.self, from: Data(contentsOf: url))
                try validateJournal(journal, groupID: id, workspace: workspace)
                let memberIDs = try Set(groupMembers(id, context: context).map(\.id))
                    .union(journal.restoreMemberIDs ?? []).union([journal.originalRecord.id])
                let reservation = try reservations.reserve(sessionIDs: memberIDs, groupID: id)
                defer { reservations.release(reservation) }
                let saved = ModelContext(context.container)
                guard let target = try RecordingSession.fetch(id: journal.originalRecord.id, in: saved),
                      let result = journal.results.first(where: { $0.sessionID == target.id }) else {
                    throw SpliceError.stalePlan
                }
                let committed = target.spliceGroupID == (journal.operation == "restore" ? nil : id)
                    && target.createdAt == result.createdAt && target.duration == result.duration
                let before = target.spliceGroupID == journal.originalRecord.spliceGroupID
                    && target.createdAt == journal.originalRecord.createdAt && target.duration == journal.originalRecord.duration
                if committed {
                    if journal.operation == "restore" {
                        _ = try await finishRestore(journal, workspace: workspace, context: context, coordinator: coordinator, reservation: reservation)
                    } else {
                        try removeIfPresent(journal.stagingFolder)
                        try removeIfPresent(url)
                    }
                } else if before {
                    if journal.rollbackCompleted != true {
                        try rollback(journal)
                        try markRollbackCompleted(journal, at: url)
                    }
                    for folder in journal.newFolders { try removeIfPresent(folder) }
                    try removeIfPresent(journal.stagingFolder)
                    if journal.createsGroup { try removeIfPresent(group) }
                    else { try removeIfPresent(url) }
                } else { throw SpliceError.stalePlan }
            } catch {
                logger.error("Kept splice journal \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Trim migration

    /// Turns every live trimmed recording of the workspace into a group of one. A stopped process
    /// leaves a journal that the next reconciliation resolves before migrating again.
    private func migrateTrimmedSessions(workspace: Workspace, context: ModelContext) {
        let trimmed: [RecordingSession]
        do { trimmed = try context.fetch(FetchDescriptor<RecordingSession>()).filter { $0.originalMixdownURL != nil } }
        catch {
            logger.error("Cannot read trimmed sessions: \(error.localizedDescription, privacy: .public)")
            return
        }
        for session in trimmed {
            do { try migrateTrim(of: session, workspace: workspace, context: context) }
            catch is SpliceFileOperations.Interruption { return }
            catch {
                logger.error("Trim migration of \(session.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Migrates one trimmed recording, such as one just recovered from Pending deletions, at its
    /// current folder. Failures are logged and leave the session as it was.
    func migrateTrimIfNeeded(_ session: RecordingSession, workspace: Workspace, context: ModelContext) {
        guard session.originalMixdownURL != nil else { return }
        do { try migrateTrim(of: session, workspace: workspace, context: context) }
        catch {
            logger.error("Trim migration of \(session.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The backups move into a new group folder as its original files. The trimmed files, the
    /// transcripts and `transcript.md` stay; the session's duration becomes the trim end.
    private func migrateTrim(of session: RecordingSession, workspace: Workspace, context: ModelContext) throws {
        guard let backupPath = session.originalMixdownURL, !session.isDeleted, session.modelContext === context else { return }
        let folder = URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
        guard isSessionFolder(folder, workspace: workspace) else { return }
        guard session.spliceGroupID == nil else {
            logger.error("Trim migration skipped \(session.id, privacy: .public): the session is already in a splice group.")
            return
        }
        guard let trimEnd = session.trimEnd, trimEnd.isFinite, trimEnd > 0, trimEnd <= session.duration else {
            logger.error("Trim migration skipped \(session.id, privacy: .public): the trim end is missing or invalid.")
            return
        }
        // The folder may have been recovered from Pending deletions, so the backups are found by
        // name in the session's current folder.
        let audioBackup = folder.appendingPathComponent(URL(fileURLWithPath: backupPath).lastPathComponent)
        let videoBackup = session.originalScreenVideoURL.map { folder.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent) }
        for backup in [audioBackup, videoBackup].compactMap({ $0 }) where !FileManager.default.isReadableFile(atPath: backup.path) {
            logger.error("Trim migration skipped \(session.id, privacy: .public): \(backup.lastPathComponent, privacy: .public) is missing.")
            return
        }
        guard !reservations.isReserved(sessionID: session.id) else {
            logger.error("Trim migration skipped \(session.id, privacy: .public): the session is busy.")
            return
        }
        let groupID = UUID()
        let group = try Self.groupFolder(groupID, workspace: workspace)
        let reservation = try reservations.reserve(sessionIDs: [session.id], groupID: groupID)
        defer { reservations.release(reservation) }
        if context.hasChanges { try save(context) }

        let manifest = SpliceManifest(
            originalSessionID: session.id, title: session.title, createdAt: session.createdAt, duration: session.duration,
            transcriptData: session.originalTranscriptData, retranscriptData: session.originalRetranscriptData,
            hasScreenVideo: videoBackup != nil
        )
        var moves = [SpliceJournal.Move(source: audioBackup, destination: group.appendingPathComponent("recording.m4a"))]
        if let videoBackup { moves.append(.init(source: videoBackup, destination: group.appendingPathComponent("screen.mov"))) }
        let markdown = transcriptMarkdownURL(for: session)
        var journal = SpliceJournal(
            groupID: groupID, createsGroup: true, originalRecord: RecordingSessionRecord(session), moves: moves,
            newFolders: [], stagingFolder: workspace.rootURL.appendingPathComponent("_splice_" + UUID().uuidString, isDirectory: true),
            markdownURL: markdown, previousMarkdown: exists(markdown) ? try Data(contentsOf: markdown) : nil,
            results: [.init(sessionID: session.id, createdAt: session.createdAt, duration: trimEnd, title: session.title,
                            transcriptData: session.transcriptData, retranscriptData: session.retranscriptData)],
            startedAt: now()
        )
        journal.operation = "migrate"
        let journalURL = group.appendingPathComponent(SpliceJournal.fileName)
        var madeGroup = false
        var modelsTouched = false
        do {
            try files.createDirectory(group, true)
            madeGroup = true
            try files.write(JSONEncoder().encode(journal), journalURL)
            for move in moves { try files.move(move.source, move.destination) }
            try files.write(JSONEncoder().encode(manifest), group.appendingPathComponent(SpliceManifest.fileName))
            modelsTouched = true
            session.duration = trimEnd
            session.spliceGroupID = groupID
            session.originalMixdownURL = nil
            session.originalScreenVideoURL = nil
            session.originalTranscriptData = nil
            session.originalRetranscriptData = nil
            session.trimEnd = nil
            try save(context)
            try files.checkpoint(.storeSaved)
            do { try files.remove(journalURL) }
            catch {
                if error is SpliceFileOperations.Interruption { throw error }
                logger.error("Trim migration committed; cleanup remains in journal: \(error.localizedDescription, privacy: .public)")
            }
        } catch {
            if modelsTouched { context.rollback() }
            if error is SpliceFileOperations.Interruption { throw error }
            do {
                if exists(journalURL) {
                    try rollback(journal)
                    try markRollbackCompleted(journal, at: journalURL)
                }
                if madeGroup { try removeIfPresent(group) }
            } catch {
                logger.error("Trim migration rollback failed; journal retained: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    private func validateJournal(_ journal: SpliceJournal, groupID: UUID, workspace: Workspace) throws {
        let original = URL(fileURLWithPath: journal.originalRecord.micAudioURL).deletingLastPathComponent()
        let staging = journal.stagingFolder.standardizedFileURL
        let prefix = journal.operation == "restore" ? "_restore_" : "_splice_"
        guard journal.formatVersion == 1, ["splice", "restore", "migrate"].contains(journal.operation),
              journal.groupID == groupID, isSessionFolder(original, workspace: workspace),
              staging.deletingLastPathComponent().path == workspace.rootURL.standardizedFileURL.path,
              staging.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(staging.lastPathComponent.dropFirst(prefix.count))) != nil,
              staging.resolvingSymlinksInPath().path == workspace.rootURL.resolvingSymlinksInPath()
                .appendingPathComponent(staging.lastPathComponent).path,
              journal.newFolders.allSatisfy({ isSessionFolder($0, workspace: workspace) && $0.standardizedFileURL != original.standardizedFileURL }),
              journal.markdownURL.standardizedFileURL == original.appendingPathComponent("transcript.md").standardizedFileURL,
              !journal.results.isEmpty,
              journal.results.allSatisfy({ $0.duration.isFinite && $0.duration > 0 }),
              journal.operation != "restore" || (!journal.createsGroup && journal.newFolders.isEmpty && journal.restoreMemberIDs != nil),
              journal.operation != "migrate" || (journal.createsGroup && journal.newFolders.isEmpty && journal.results.count == 1)
        else { throw SpliceError.inactiveWorkspace }
        let group = try Self.groupFolder(groupID, workspace: workspace)
        let folders = [original, staging, group] + journal.newFolders
        for file in journal.moves.flatMap({ [$0.source, $0.destination] }) + [journal.markdownURL] {
            guard file.isFileURL, folders.contains(where: {
                file.standardizedFileURL.deletingLastPathComponent() == $0.standardizedFileURL
                    && file.resolvingSymlinksInPath().path == $0.resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent).path
            }) else { throw SpliceError.inactiveWorkspace }
        }
    }

    private func groupMembers(_ id: UUID, context: ModelContext) throws -> [RecordingSession] {
        try context.fetch(FetchDescriptor<RecordingSession>()).filter { $0.spliceGroupID == id }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }

    enum GroupCleanupResult: Equatable {
        case removed
        case absent
        case inUse
        case journalPresent
        case membershipUnavailable
        case invalidPath
        case removalFailed
    }

    /// No await separates the membership read from removal. Unknown membership always keeps the
    /// group; a journal belongs to reconciliation and is never retired here.
    @discardableResult
    func removeGroupIfUnused(_ id: UUID, workspace: Workspace, context: ModelContext) -> GroupCleanupResult {
        removeGroupIfUnused(id, workspace: workspace) { try self.readMembership(workspace: workspace, context: context) }
    }

    /// Also retries orphans whose last known member was removed while another snapshot was
    /// unreadable. Reconciliation can call this after it has processed journals.
    @discardableResult
    func sweepUnusedGroups(workspace: Workspace, context: ModelContext) -> [UUID: GroupCleanupResult] {
        let parent = workspace.rootURL.appendingPathComponent("splice", isDirectory: true)
        let expected = workspace.rootURL.resolvingSymlinksInPath().appendingPathComponent("splice", isDirectory: true)
        guard parent.resolvingSymlinksInPath().path == expected.path else {
            logger.error("Kept splice groups because the splice folder is outside the workspace.")
            return [:]
        }
        let entries: [URL]
        do { entries = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) }
        catch {
            if !Self.isMissingFile(error) {
                logger.error("Kept splice groups because their folder could not be read: \(error.localizedDescription, privacy: .public)")
            }
            return [:]
        }
        let ids = entries.compactMap { UUID(uuidString: $0.lastPathComponent) }
        var cachedMembership: Result<Set<UUID>, Error>?
        var results: [UUID: GroupCleanupResult] = [:]
        for id in ids {
            results[id] = removeGroupIfUnused(id, workspace: workspace) {
                if let cachedMembership { return try cachedMembership.get() }
                let groups = Result { try self.readMembership(workspace: workspace, context: context) }
                cachedMembership = groups
                return try groups.get()
            }
        }
        return results
    }

    private func readMembership(workspace: Workspace, context: ModelContext) throws -> Set<UUID> {
        let live: Set<UUID>
        do { live = try membership.liveGroupIDs(context) }
        catch {
            logger.error("Kept splice groups because store membership could not be fetched: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        do { return try live.union(membership.heldGroupIDs(workspace)) }
        catch {
            logger.error("Kept splice groups because holding membership could not be read: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func removeGroupIfUnused(
        _ id: UUID, workspace: Workspace, readMembership: () throws -> Set<UUID>
    ) -> GroupCleanupResult {
        let group: URL
        do { group = try Self.groupFolder(id, workspace: workspace) }
        catch {
            logger.error("Kept splice group \(id, privacy: .public) because its path is outside the splice folder.")
            return .invalidPath
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: group.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                logger.error("Kept splice group \(id, privacy: .public) because its path is not a directory.")
                return .invalidPath
            }
        } catch {
            if Self.isMissingFile(error) { return .absent }
            logger.error("Kept splice group \(id, privacy: .public) because its folder could not be read: \(error.localizedDescription, privacy: .public)")
            return .membershipUnavailable
        }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: group.appendingPathComponent(SpliceJournal.fileName).path)
            return .journalPresent
        } catch {
            guard Self.isMissingFile(error) else {
                logger.error("Kept splice group \(id, privacy: .public) because its journal could not be checked: \(error.localizedDescription, privacy: .public)")
                return .membershipUnavailable
            }
        }
        do {
            guard try !readMembership().contains(id) else { return .inUse }
        } catch { return .membershipUnavailable }
        do {
            try files.remove(group)
            return .removed
        } catch {
            logger.error("Kept splice group \(id, privacy: .public) because removal failed: \(error.localizedDescription, privacy: .public)")
            return .removalFailed
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }

    private struct Output {
        let id: UUID
        let createdAt: Date
        let duration: Double
        let title: String
        let transcript: Transcript?
        let retranscript: Transcript?
        let audio: URL
        let video: URL?

        func result() throws -> SpliceJournal.Result {
            try .init(sessionID: id, createdAt: createdAt, duration: duration, title: title,
                      transcriptData: transcript.map { try JSONEncoder().encode($0) },
                      retranscriptData: retranscript.map { try JSONEncoder().encode($0) })
        }
    }

    private func rollback(_ journal: SpliceJournal) throws {
        for move in journal.moves.reversed() where exists(move.destination) && !exists(move.source) {
            try files.move(move.destination, move.source)
        }
        if let bytes = journal.previousMarkdown {
            try files.write(bytes, journal.markdownURL)
        } else {
            try removeIfPresent(journal.markdownURL)
        }
    }

    private func checkDiskSpace(_ urls: [URL], workspace: Workspace) throws {
        var required: Int64 = 0
        for url in urls {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let (sum, overflow) = required.addingReportingOverflow(Int64(size))
            guard !overflow else { throw SpliceError.insufficientDiskSpace }
            required = sum
        }
        guard let available = capacity(workspace.rootURL), available >= required else {
            throw SpliceError.insufficientDiskSpace
        }
    }

    private func decodePass(_ data: Data?) throws -> Transcript? {
        guard let data else { return nil }
        guard let pass = try? JSONDecoder().decode(Transcript.self, from: data) else { throw SpliceError.missingTranscript }
        return pass
    }

    private func readManifest(in group: URL) throws -> SpliceManifest {
        guard let manifest = try? JSONDecoder().decode(SpliceManifest.self, from: Data(contentsOf: group.appendingPathComponent(SpliceManifest.fileName))),
              manifest.formatVersion == 1, manifest.duration.isFinite, manifest.duration > 0,
              FileManager.default.isReadableFile(atPath: group.appendingPathComponent("recording.m4a").path),
              !manifest.hasScreenVideo || FileManager.default.isReadableFile(atPath: group.appendingPathComponent("screen.mov").path)
        else { throw SpliceError.missingOriginal }
        return manifest
    }

    static func groupFolder(_ id: UUID, workspace: Workspace) throws -> URL {
        let parent = workspace.rootURL.appendingPathComponent("splice", isDirectory: true)
        let group = parent.appendingPathComponent(id.uuidString, isDirectory: true)
        let expected = workspace.rootURL.resolvingSymlinksInPath()
            .appendingPathComponent("splice", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        guard parent.resolvingSymlinksInPath().deletingLastPathComponent().path == workspace.rootURL.resolvingSymlinksInPath().path,
              group.resolvingSymlinksInPath().path == expected.standardizedFileURL.path else {
            throw SpliceError.inactiveWorkspace
        }
        return group
    }

    private func isSessionFolder(_ folder: URL, workspace: Workspace) -> Bool {
        let recordings = workspace.recordingsURL.resolvingSymlinksInPath()
        return recordings.deletingLastPathComponent().path == workspace.rootURL.resolvingSymlinksInPath().path
            && folder.resolvingSymlinksInPath().deletingLastPathComponent().path == recordings.path
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func removeIfPresent(_ url: URL) throws {
        if exists(url) { try files.remove(url) }
    }

    static func exportTimeRange(from source: URL, to destination: URL, start: Double, end: Double) async throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw SpliceError.invalidPlan }
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw SpliceError.exportFailed
        }
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 60_000),
            end: CMTime(seconds: end, preferredTimescale: 60_000)
        )
        try await exporter.export(to: destination, as: destination.pathExtension.lowercased() == "mov" ? .mov : .m4a)
    }
}
