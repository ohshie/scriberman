import AVFoundation
import Foundation

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

    // MARK: - Trim

    func trim(session: RecordingSession, end trimEnd: Double) async throws {
        guard !session.isTrimmed else { throw AudioTrimError.alreadyTrimmed }
        guard let mixdownPath = session.mixdownURL, !mixdownPath.isEmpty else { throw AudioTrimError.missingMixdown }

        let mixdownURL = URL(fileURLWithPath: mixdownPath)
        guard trimEnd < session.duration else { throw AudioTrimError.trimEndExceedsDuration }

        try checkDiskSpace(for: mixdownURL)

        let originalMixdownURL = backupURL(for: mixdownURL, suffix: "-original")
        let originalScreenVideoURL: URL? = try {
            guard let screenPath = session.screenVideoURL, !screenPath.isEmpty else { return nil }
            let screenURL = URL(fileURLWithPath: screenPath)
            guard FileManager.default.fileExists(atPath: screenURL.path) else { return nil }
            return backupURL(for: screenURL, suffix: "-original")
        }()

        // Snapshot transcripts before modifying
        let originalTranscriptData = session.transcriptData
        let originalRetranscriptData = session.retranscriptData

        // Backup and export audio
        try FileManager.default.copyItem(at: mixdownURL, to: originalMixdownURL)
        do {
            try await exportTimeRange(from: mixdownURL, to: mixdownURL, end: trimEnd)
        } catch {
            try? FileManager.default.removeItem(at: originalMixdownURL)
            throw error
        }

        // Backup and export screen video if present
        if let screenPath = session.screenVideoURL, !screenPath.isEmpty,
           let backupScreenURL = originalScreenVideoURL {
            let screenURL = URL(fileURLWithPath: screenPath)
            if FileManager.default.fileExists(atPath: screenURL.path) {
                try FileManager.default.copyItem(at: screenURL, to: backupScreenURL)
                do {
                    try await exportTimeRange(from: screenURL, to: screenURL, end: trimEnd)
                } catch {
                    // Roll back audio changes
                    try? FileManager.default.removeItem(at: mixdownURL)
                    try? FileManager.default.copyItem(at: originalMixdownURL, to: mixdownURL)
                    try? FileManager.default.removeItem(at: originalMixdownURL)
                    try? FileManager.default.removeItem(at: backupScreenURL)
                    throw error
                }
            }
        }

        // Persist backup URLs and trim point
        session.originalMixdownURL = originalMixdownURL.path
        session.originalScreenVideoURL = originalScreenVideoURL?.path
        session.trimEnd = trimEnd

        // Adjust transcripts
        session.originalTranscriptData = originalTranscriptData
        session.originalRetranscriptData = originalRetranscriptData

        if let transcript = session.transcript {
            session.transcript = Transcript(
                fullText: transcript.fullText,
                segments: Self.filterSegments(transcript.segments, trimEnd: Float(trimEnd)),
                speakers: transcript.speakers,
                speakerEmbeddings: transcript.speakerEmbeddings
            )
        }

        if let retranscript = session.retranscript {
            session.retranscript = Transcript(
                fullText: retranscript.fullText,
                segments: Self.filterSegments(retranscript.segments, trimEnd: Float(trimEnd)),
                speakers: retranscript.speakers,
                speakerEmbeddings: retranscript.speakerEmbeddings
            )
        }
    }

    // MARK: - Restore

    func restore(session: RecordingSession) async throws {
        guard session.isTrimmed, let originalMixdownPath = session.originalMixdownURL else {
            throw AudioTrimError.notTrimmed
        }

        let originalMixdownURL = URL(fileURLWithPath: originalMixdownPath)
        guard let currentMixdownPath = session.mixdownURL else { throw AudioTrimError.missingMixdown }
        let currentMixdownURL = URL(fileURLWithPath: currentMixdownPath)

        // Restore audio
        try FileManager.default.removeItem(at: currentMixdownURL)
        try FileManager.default.moveItem(at: originalMixdownURL, to: currentMixdownURL)

        // Restore screen video if applicable
        if let originalScreenPath = session.originalScreenVideoURL,
           let currentScreenPath = session.screenVideoURL {
            let originalScreenURL = URL(fileURLWithPath: originalScreenPath)
            let currentScreenURL = URL(fileURLWithPath: currentScreenPath)
            if FileManager.default.fileExists(atPath: originalScreenURL.path) {
                try? FileManager.default.removeItem(at: currentScreenURL)
                try? FileManager.default.moveItem(at: originalScreenURL, to: currentScreenURL)
            }
        }

        // Restore transcript blobs
        session.transcriptData = session.originalTranscriptData
        session.retranscriptData = session.originalRetranscriptData

        // Clear all trim state
        session.originalMixdownURL = nil
        session.originalScreenVideoURL = nil
        session.originalTranscriptData = nil
        session.originalRetranscriptData = nil
        session.trimEnd = nil
    }

    // MARK: - Private helpers

    private func checkDiskSpace(for url: URL) throws {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let values = try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? 0
        if available < Int64(fileSize) {
            throw AudioTrimError.insufficientDiskSpace
        }
    }

    private func backupURL(for url: URL, suffix: String) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent(stem + suffix)
            .appendingPathExtension(ext)
    }

    private func exportTimeRange(from sourceURL: URL, to destinationURL: URL, end: Double) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let endTime = CMTime(seconds: end, preferredTimescale: duration.timescale)
        let timeRange = CMTimeRange(start: .zero, end: endTime)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioTrimError.exportFailed("Could not create export session")
        }

        exportSession.timeRange = timeRange

        let fileType = outputFileType(for: destinationURL)
        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent("_trim_temp_\(UUID().uuidString)")
            .appendingPathExtension(destinationURL.pathExtension)

        do {
            try await exportSession.export(to: tempURL, as: fileType)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw AudioTrimError.exportFailed(error.localizedDescription)
        }

        // Atomically replace destination
        try FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }

    private func outputFileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "m4a": return .m4a
        case "mov": return .mov
        default: return .m4a
        }
    }

    // MARK: - Transcript filtering

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
