import Foundation
import OSLog
import SwiftData

/// One reversible rename of one pass across the live group and its original transcript.
/// Preparing the edit does not change models or files. Applying it has no suspension points.
@MainActor
struct SpliceSpeakerRename {
    private static let logger = Logger(subsystem: "Scriberman", category: "SpliceSpeakerRename")
    private struct Member {
        let id: UUID
        let before: Data
        let after: Data
        var reversed: Self { .init(id: id, before: after, after: before) }
    }
    private struct FileEdit {
        let memberID: UUID?
        let url: URL
        let before: Data?
        let after: Data?
        var reversed: Self { .init(memberID: memberID, url: url, before: after, after: before) }
    }

    private let context: ModelContext
    private let workspace: Workspace
    private let groupID: UUID
    private let origin: UUID
    private let pass: TranscriptPass
    private let sourceID: UUID
    private var members: [Member]
    private var files: [FileEdit]

    init(session: RecordingSession, transcript: Transcript, speakerID: String, name: String) throws {
        guard let context = session.modelContext, let groupID = session.spliceGroupID,
              let origin = transcript.spliceOriginSessionID, !session.isDeleted,
              session.displayedTranscript == transcript else { throw SpliceError.stalePlan }
        self.context = context
        self.groupID = groupID
        self.origin = origin
        sourceID = session.id
        pass = TranscriptDetailViewModel.displayedPass(of: session)
        let folder = URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
        workspace = Workspace(rootURL: folder.deletingLastPathComponent().deletingLastPathComponent())
        let group = try SpliceService.groupFolder(groupID, workspace: workspace)
        let manifestURL = group.appendingPathComponent(SpliceManifest.fileName)
        try Self.validateFile(manifestURL, parent: group)
        let manifestBefore = try Data(contentsOf: manifestURL)
        var manifest = try JSONDecoder().decode(SpliceManifest.self, from: manifestBefore)
        guard manifest.formatVersion == 1 else { throw SpliceError.missingOriginal }
        let originalData = pass == .transcript ? manifest.transcriptData : manifest.retranscriptData
        if let originalData {
            let original = try JSONDecoder().decode(Transcript.self, from: originalData)
            if (original.spliceOriginSessionID ?? manifest.originalSessionID) == origin,
               let renamed = TranscriptSpeakerEditing.rename(speakerID, to: name, in: original) {
                let data = try JSONEncoder().encode(renamed)
                if pass == .transcript { manifest.transcriptData = data }
                else { manifest.retranscriptData = data }
            }
        }
        members = []
        files = []
        for member in try context.fetch(FetchDescriptor<RecordingSession>()) where member.spliceGroupID == groupID {
            guard let before = Self.data(for: member, pass: pass) else { continue }
            let current = try JSONDecoder().decode(Transcript.self, from: before)
            guard current.spliceOriginSessionID == origin,
                  let renamed = TranscriptSpeakerEditing.rename(speakerID, to: name, in: current) else { continue }
            try Self.validateFolder(of: member, workspace: workspace)
            let after = try JSONEncoder().encode(renamed)
            members.append(Member(id: member.id, before: before, after: after))
            let markdown = transcriptMarkdownURL(for: member)
            try Self.validateFile(markdown, parent: markdown.deletingLastPathComponent())
            let displayed = pass == .retranscript ? renamed : (member.retranscript ?? renamed)
            files.append(FileEdit(memberID: member.id, url: markdown, before: try Self.readIfPresent(markdown),
                after: Data(MarkdownRenderer().renderMarkdown(session: member, transcript: displayed).utf8)))
        }
        guard members.contains(where: { $0.id == session.id }) else { throw SpliceError.stalePlan }
        files.append(FileEdit(memberID: nil, url: manifestURL, before: manifestBefore, after: try JSONEncoder().encode(manifest)))
    }

    var reversed: Self {
        var copy = self
        copy.members = members.map(\.reversed)
        copy.files = files.map(\.reversed)
        return copy
    }

    func apply(
        saveContext: (ModelContext) throws -> Void,
        writeData: (Data, URL) throws -> Void
    ) throws {
        let group = try SpliceService.groupFolder(groupID, workspace: workspace)
        guard !FileManager.default.fileExists(atPath: group.appendingPathComponent(SpliceJournal.fileName).path) else {
            throw SpliceError.busy
        }
        var live: [(Member, RecordingSession)] = []
        for change in members {
            // Deleted, detached and retranscribed members no longer participate in this edit.
            guard let member = try RecordingSession.fetch(id: change.id, in: context), member.spliceGroupID == groupID,
                  let current = Self.data(for: member, pass: pass),
                  try JSONDecoder().decode(Transcript.self, from: current).spliceOriginSessionID == origin else { continue }
            guard !SpliceReservations.shared.isReserved(member) else { throw SpliceError.busy }
            if change.id == sourceID, TranscriptDetailViewModel.displayedPass(of: member) != pass { throw SpliceError.stalePlan }
            guard try JSONDecoder().decode(Transcript.self, from: current) == JSONDecoder().decode(Transcript.self, from: change.before) else {
                throw SpliceError.stalePlan
            }
            try Self.validateFolder(of: member, workspace: workspace)
            live.append((change, member))
        }
        let ids = Set(live.map { $0.0.id })
        guard ids.contains(sourceID) else { throw SpliceError.stalePlan }
        let edits = files.filter { $0.memberID.map(ids.contains) ?? true }
        for edit in edits {
            try Self.validateFile(edit.url, parent: edit.memberID == nil ? group : edit.url.deletingLastPathComponent())
            guard try Self.readIfPresent(edit.url) == edit.before else { throw SpliceError.stalePlan }
        }
        var attempted: [FileEdit] = []
        do {
            for edit in edits {
                attempted.append(edit)
                try Self.write(edit.after, at: edit.url, writeData: writeData)
            }
            for (change, member) in live { Self.setData(change.after, for: member, pass: pass) }
            try saveContext(context)
        } catch {
            for (change, member) in live { Self.setData(change.before, for: member, pass: pass) }
            for edit in attempted.reversed() {
                do { try Self.write(edit.before, at: edit.url, writeData: writeData) }
                catch { Self.logger.error("Restoring a speaker rename file failed: \(error.localizedDescription, privacy: .public)") }
            }
            throw error
        }
    }

    private static func data(for session: RecordingSession, pass: TranscriptPass) -> Data? {
        pass == .transcript ? session.transcriptData : session.retranscriptData
    }

    private static func setData(_ data: Data, for session: RecordingSession, pass: TranscriptPass) {
        session.restoreTranscripts(transcriptData: pass == .transcript ? data : session.transcriptData,
            retranscriptData: pass == .retranscript ? data : session.retranscriptData)
    }

    private static func validateFolder(of session: RecordingSession, workspace: Workspace) throws {
        let folder = URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
        guard folder.standardizedFileURL.deletingLastPathComponent() == workspace.recordingsURL.standardizedFileURL,
              folder.resolvingSymlinksInPath().path == workspace.recordingsURL.resolvingSymlinksInPath()
                .appendingPathComponent(folder.lastPathComponent).path else { throw SpliceError.inactiveWorkspace }
    }

    private static func validateFile(_ url: URL, parent: URL) throws {
        guard url.resolvingSymlinksInPath().path == parent.resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path else {
            throw SpliceError.inactiveWorkspace
        }
    }

    private static func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return nil
        }
    }

    private static func write(_ data: Data?, at url: URL, writeData: (Data, URL) throws -> Void) throws {
        if let data { try writeData(data, url) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
