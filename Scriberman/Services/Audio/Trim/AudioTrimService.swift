import AVFoundation
import Foundation
import OSLog
import SwiftData

enum AudioTrimError: LocalizedError, Equatable {
    case alreadyTrimmed
    case trimEndExceedsDuration
    case insufficientDiskSpace
    case missingMixdown
    case exportFailed(String)
    case notTrimmed

    var errorDescription: String? {
        switch self {
        case .alreadyTrimmed:
            return "This recording has already been trimmed. Restore the original before trimming again."
        case .trimEndExceedsDuration:
            return "The trim point must be before the end of the recording."
        case .insufficientDiskSpace:
            return "Not enough disk space to create the trimmed file. Free up some space and try again."
        case .missingMixdown:
            return "The recording audio file could not be found."
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .notTrimmed:
            return "This recording has not been trimmed."
        }
    }
}

@MainActor
final class AudioTrimService {
    /// Free bytes on the volume holding the given folder, or `nil` when it cannot be read.
    typealias CapacityProvider = (URL) -> Int64?
    /// Exports `[0, end]` of the source file into a new file at the destination.
    typealias Export = (_ source: URL, _ destination: URL, _ end: Double) async throws -> Void
    /// Replaces `original` with `replacement`. With a backup name the pre-replacement file is
    /// kept under that name in the same folder; without one it is deleted.
    typealias ReplaceItem = (_ original: URL, _ replacement: URL, _ backupName: String?) throws -> Void
    typealias SaveContext = (ModelContext) throws -> Void

    private static let tempPrefix = "_trim_temp_"
    private let logger = Logger(subsystem: "Scriberman", category: "AudioTrimService")

    private let capacityProvider: CapacityProvider
    private let export: Export
    private let replaceItem: ReplaceItem
    private let saveContext: SaveContext

    init(
        capacityProvider: CapacityProvider? = nil,
        export: Export? = nil,
        replaceItem: ReplaceItem? = nil,
        saveContext: SaveContext? = nil
    ) {
        self.capacityProvider = capacityProvider ?? { folderURL in
            let values = try? folderURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }
        self.export = export ?? { source, destination, end in
            try await Self.exportTimeRange(from: source, to: destination, end: end)
        }
        self.replaceItem = replaceItem ?? { original, replacement, backupName in
            _ = try FileManager.default.replaceItemAt(
                original,
                withItemAt: replacement,
                backupItemName: backupName,
                options: backupName == nil ? [] : .withoutDeletingBackupItem
            )
        }
        self.saveContext = saveContext ?? { context in
            try context.save()
        }
    }

    // MARK: - Trim

    /// Trims the recording to `[0, trimEnd]` as one transaction: every output is exported before
    /// any existing file is touched, the files are swapped keeping `-original` backups, and the
    /// session is saved. A failure at any step puts the pre-trim files back and leaves the
    /// session's trim fields as they were.
    func trim(session: RecordingSession, end trimEnd: Double, context: ModelContext) async throws {
        guard !session.isTrimmed else { throw AudioTrimError.alreadyTrimmed }
        guard let mixdownPath = session.mixdownURL, !mixdownPath.isEmpty else { throw AudioTrimError.missingMixdown }
        let mixdownURL = URL(fileURLWithPath: mixdownPath)
        guard FileManager.default.fileExists(atPath: mixdownURL.path) else { throw AudioTrimError.missingMixdown }
        guard trimEnd.isFinite, trimEnd > 0, trimEnd < session.duration else {
            throw AudioTrimError.trimEndExceedsDuration
        }

        let screenURL: URL? = {
            guard let screenPath = session.screenVideoURL, !screenPath.isEmpty else { return nil }
            let url = URL(fileURLWithPath: screenPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }()

        let originalMixdownURL = backupURL(for: mixdownURL)
        let originalScreenURL = screenURL.map(backupURL(for:))
        // `replaceItemAt` overwrites an existing backup silently. A leftover `-original` file is
        // the pre-trim recording from an interrupted trim, so it must never be the one replaced.
        for backup in [originalMixdownURL, originalScreenURL].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: backup.path) {
            throw AudioTrimError.alreadyTrimmed
        }

        try checkDiskSpace(for: [mixdownURL, screenURL].compactMap { $0 })

        // 1. Stage every output. Nothing existing is touched until all exports succeed.
        let tempMixdownURL = tempURL(beside: mixdownURL)
        let tempScreenURL = screenURL.map(tempURL(beside:))
        let temps = [tempMixdownURL, tempScreenURL].compactMap { $0 }
        defer { removeItems(temps) }

        try await export(mixdownURL, tempMixdownURL, trimEnd)
        if let screenURL, let tempScreenURL {
            try await export(screenURL, tempScreenURL, trimEnd)
        }

        // 2. Swap files, keeping the pre-trim versions as `-original` backups.
        try replaceItem(mixdownURL, tempMixdownURL, originalMixdownURL.lastPathComponent)
        if let screenURL, let tempScreenURL, let originalScreenURL {
            do {
                try replaceItem(screenURL, tempScreenURL, originalScreenURL.lastPathComponent)
            } catch {
                putBack(originalMixdownURL, at: mixdownURL)
                throw error
            }
        }

        // 3. Record the trim and save it.
        let previous = TrimFields(session)
        session.originalTranscriptData = session.transcriptData
        session.originalRetranscriptData = session.retranscriptData
        if let transcript = session.transcript {
            session.transcript = Self.trimmedTranscript(transcript, end: Float(trimEnd))
        }
        if let retranscript = session.retranscript {
            session.retranscript = Self.trimmedTranscript(retranscript, end: Float(trimEnd))
        }
        session.originalMixdownURL = originalMixdownURL.path
        session.originalScreenVideoURL = originalScreenURL?.path
        session.trimEnd = trimEnd

        do {
            try saveContext(context)
        } catch {
            previous.apply(to: session)
            if let screenURL, let originalScreenURL {
                putBack(originalScreenURL, at: screenURL)
            }
            putBack(originalMixdownURL, at: mixdownURL)
            throw error
        }

        rewriteTranscriptMarkdown(for: session, end: Float(trimEnd))
    }

    // MARK: - Restore

    /// Reverses a trim as one transaction: the `-original` files are swapped back, the session is
    /// saved untrimmed, and only then are the trimmed files deleted. A failure at any step puts the
    /// trimmed files back and leaves the session marked trimmed, so restore can be retried.
    func restore(session: RecordingSession, context: ModelContext) async throws {
        guard session.isTrimmed, let originalMixdownPath = session.originalMixdownURL else {
            throw AudioTrimError.notTrimmed
        }
        guard let mixdownPath = session.mixdownURL else { throw AudioTrimError.missingMixdown }

        let mixdownURL = URL(fileURLWithPath: mixdownPath)
        let originalMixdownURL = URL(fileURLWithPath: originalMixdownPath)
        let screen: (current: URL, original: URL)? = {
            guard let originalScreenPath = session.originalScreenVideoURL,
                  let screenPath = session.screenVideoURL else { return nil }
            return (URL(fileURLWithPath: screenPath), URL(fileURLWithPath: originalScreenPath))
        }()

        // 1. Swap the originals back, keeping the trimmed files under temporary names.
        let trimmedMixdownURL = tempURL(beside: mixdownURL)
        let trimmedScreenURL = screen.map { tempURL(beside: $0.current) }

        try replaceItem(mixdownURL, originalMixdownURL, trimmedMixdownURL.lastPathComponent)
        if let screen, let trimmedScreenURL {
            do {
                try replaceItem(screen.current, screen.original, trimmedScreenURL.lastPathComponent)
            } catch {
                swapBack(trimmedMixdownURL, at: mixdownURL, keeping: originalMixdownURL)
                throw error
            }
        }

        // 2. Clear the trim and save it.
        let previous = TrimFields(session)
        session.restoreTranscripts(
            transcriptData: session.originalTranscriptData,
            retranscriptData: session.originalRetranscriptData
        )
        session.originalMixdownURL = nil
        session.originalScreenVideoURL = nil
        session.originalTranscriptData = nil
        session.originalRetranscriptData = nil
        session.trimEnd = nil

        do {
            try saveContext(context)
        } catch {
            previous.apply(to: session)
            if let screen, let trimmedScreenURL {
                swapBack(trimmedScreenURL, at: screen.current, keeping: screen.original)
            }
            swapBack(trimmedMixdownURL, at: mixdownURL, keeping: originalMixdownURL)
            throw error
        }

        // 3. Retire the trimmed files.
        removeItems([trimmedMixdownURL, trimmedScreenURL].compactMap { $0 })
        rewriteTranscriptMarkdown(for: session)
    }

    // MARK: - Private helpers

    /// The session fields a trim or restore changes, captured so a failed save can put them back.
    private struct TrimFields {
        let transcriptData: Data?
        let retranscriptData: Data?
        let originalTranscriptData: Data?
        let originalRetranscriptData: Data?
        let originalMixdownURL: String?
        let originalScreenVideoURL: String?
        let trimEnd: Double?

        init(_ session: RecordingSession) {
            transcriptData = session.transcriptData
            retranscriptData = session.retranscriptData
            originalTranscriptData = session.originalTranscriptData
            originalRetranscriptData = session.originalRetranscriptData
            originalMixdownURL = session.originalMixdownURL
            originalScreenVideoURL = session.originalScreenVideoURL
            trimEnd = session.trimEnd
        }

        func apply(to session: RecordingSession) {
            session.restoreTranscripts(transcriptData: transcriptData, retranscriptData: retranscriptData)
            session.originalTranscriptData = originalTranscriptData
            session.originalRetranscriptData = originalRetranscriptData
            session.originalMixdownURL = originalMixdownURL
            session.originalScreenVideoURL = originalScreenVideoURL
            session.trimEnd = trimEnd
        }
    }

    /// Rolls a trim swap back: `backup` replaces the file at `url`, and the trimmed file is deleted.
    private func putBack(_ backup: URL, at url: URL) {
        do {
            try replaceItem(url, backup, nil)
        } catch {
            logger.error("Trim rollback failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public); pre-trim file kept at \(backup.lastPathComponent, privacy: .public)")
        }
    }

    /// Rolls a restore swap back: `trimmed` returns to `url`, and the file there returns to `original`.
    private func swapBack(_ trimmed: URL, at url: URL, keeping original: URL) {
        do {
            try replaceItem(url, trimmed, original.lastPathComponent)
        } catch {
            logger.error("Restore rollback failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public); trimmed file kept at \(trimmed.lastPathComponent, privacy: .public)")
        }
    }

    private func checkDiskSpace(for urls: [URL]) throws {
        let required = urls.reduce(Int64(0)) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return total + size
        }
        guard let folderURL = urls.first?.deletingLastPathComponent() else { return }
        let available = capacityProvider(folderURL) ?? 0
        if available < required {
            throw AudioTrimError.insufficientDiskSpace
        }
    }

    private func backupURL(for url: URL) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent(stem + "-original")
            .appendingPathExtension(ext)
    }

    /// A temporary file in the same folder as `url`, so `replaceItemAt` stays on one volume.
    private func tempURL(beside url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(Self.tempPrefix + UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
    }

    private func removeItems(_ urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func exportTimeRange(from sourceURL: URL, to destinationURL: URL, end: Double) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let endTime = CMTime(seconds: end, preferredTimescale: duration.timescale)
        let timeRange = CMTimeRange(start: .zero, end: endTime)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioTrimError.exportFailed("Could not create export session")
        }

        exportSession.timeRange = timeRange

        do {
            try await exportSession.export(to: destinationURL, as: outputFileType(for: destinationURL))
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw AudioTrimError.exportFailed(error.localizedDescription)
        }
    }

    private static func outputFileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "m4a": return .m4a
        case "mov": return .mov
        default: return .m4a
        }
    }

    // MARK: - Transcript filtering

    /// `transcript` cut to `[0, end]`, with the full text rebuilt from the kept segments. A
    /// segment that straddles `end` keeps its whole text: segments carry no word timings.
    static func trimmedTranscript(_ transcript: Transcript, end: Float) -> Transcript {
        let segments = filterSegments(transcript.segments, trimEnd: end)
        return Transcript(
            fullText: Transcript.fullText(joining: segments),
            segments: segments,
            speakers: transcript.speakers,
            speakerEmbeddings: transcript.speakerEmbeddings
        )
    }

    static func filterSegments(_ segments: [TranscriptSegment], trimEnd: Float) -> [TranscriptSegment] {
        segments.compactMap { segment in
            guard segment.startTime < trimEnd else { return nil }
            if segment.endTime > trimEnd {
                return TranscriptSegment(
                    id: segment.id,
                    speakerId: segment.speakerId,
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: trimEnd,
                    audioSource: segment.audioSource,
                    isFinal: segment.isFinal
                )
            }
            return segment
        }
    }
}
