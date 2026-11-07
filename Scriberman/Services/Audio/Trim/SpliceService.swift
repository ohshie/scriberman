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
        reservations: SpliceReservations? = nil
    ) {
        self.files = files
        capacity = capacityProvider
        self.export = export ?? Self.exportTimeRange
        save = saveContext
        self.now = now
        self.reservations = reservations ?? .shared
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
        try reservations.reserve(sessionID: session.id, groupID: groupID)
        defer { reservations.release(sessionID: session.id, groupID: groupID) }
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
                if let video, let destination = output.video {
                    try await export(video, destination, boundaries[index], boundaries[index + 1])
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
                // Persist the exact bytes recorded in the journal. Re-encoding here could change
                // JSON key order and prevent recovery from recognizing the committed result.
                // This model setter also refreshes search text from the displayed pass.
                part.restoreTranscripts(
                    transcriptData: preparedJournal.results[index].transcriptData,
                    retranscriptData: preparedJournal.results[index].retranscriptData
                )
                part.spliceGroupID = groupID
                try writeTranscriptMarkdown(for: part, writeEmpty: true, writeData: files.write)
                sessions.append(part)
            }
            try save(context)
            // The save committed. Cleanup errors leave a journal; they do not report a failed
            // splice or reverse files belonging to the now-saved parts.
            do {
                try removeIfPresent(staging)
                try files.remove(journalURL)
            } catch {
                logger.error("Splice committed; cleanup remains in journal: \(error.localizedDescription, privacy: .public)")
            }
            return sessions
        } catch {
            if modelsTouched { context.rollback() }
            do {
                if let journal, exists(journalURL) {
                    try rollback(journal)
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
        guard parent.resolvingSymlinksInPath().deletingLastPathComponent().path == workspace.rootURL.resolvingSymlinksInPath().path,
              group.resolvingSymlinksInPath().deletingLastPathComponent().path == parent.resolvingSymlinksInPath().path else {
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
