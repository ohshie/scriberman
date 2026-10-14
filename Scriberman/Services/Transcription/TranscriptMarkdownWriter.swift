import Foundation
import SwiftData

/// Adds a persisted live segment to `transcript.md`, under its source, in the export's format.
///
/// The first segment creates the file with the header; later ones append a block each, so a long
/// recording does not rewrite the whole file per segment. The header's title and duration are those
/// at creation; the rewrite at stop replaces them.
func appendTranscriptSegmentToMarkdown(
    _ segment: RecordingTranscriptSegment,
    for session: RecordingSession,
    fileManager: FileManager = .default
) {
    let transcriptMarkdownURL = transcriptMarkdownURL(for: session)
    let renderer = MarkdownRenderer()
    let block = renderer.block(for: liveRow(for: segment))

    if fileManager.fileExists(atPath: transcriptMarkdownURL.path) {
        if let fileHandle = try? FileHandle(forWritingTo: transcriptMarkdownURL) {
            defer { try? fileHandle.close() }
            try? fileHandle.seekToEnd()
            if let data = block.data(using: .utf8) {
                try? fileHandle.write(contentsOf: data)
            }
        }
        return
    }

    let initialContents = renderer.header(for: session) + block
    try? initialContents.write(to: transcriptMarkdownURL, atomically: true, encoding: .utf8)
}

/// Rewrites `transcript.md` to show what the app shows, in the format export writes.
///
/// With a saved transcript, the file lists the shown pass (`displayedTranscript`) under each
/// speaker's label, so renames, recognized names and `Speaker N` read the same as in the app, and
/// the content equals the export. Without one (a recording still in progress or interrupted), it
/// lists the persisted live segments under their source, as the live view does. Segments that start
/// at or after `end` are left out and a segment that runs past it is capped; `nil` writes every
/// segment. Called whenever the shown transcript, its labels or the title change: stop, speaker and
/// session rename, retranscription, trim and restore. A session with nothing to list is left alone.
func rewriteTranscriptMarkdown(for session: RecordingSession, end: Float? = nil) {
    try? writeTranscriptMarkdown(for: session, end: end)
}

/// `rewriteTranscriptMarkdown`, reporting a failed write instead of ignoring it.
func writeTranscriptMarkdown(for session: RecordingSession, end: Float? = nil) throws {
    let rows: [MarkdownRenderer.Row]
    if let transcript = session.displayedTranscript {
        rows = MarkdownRenderer.rows(for: transcript)
    } else {
        rows = session.transcriptSegments
            .sorted { $0.createdAt < $1.createdAt }
            .map(liveRow(for:))
    }
    let fileURL = transcriptMarkdownURL(for: session)
    guard !rows.isEmpty || FileManager.default.fileExists(atPath: fileURL.path) else { return }

    let kept = rows.compactMap { row -> MarkdownRenderer.Row? in
        guard let end else { return row }
        guard row.startTime < end else { return nil }
        var capped = row
        capped.endTime = min(row.endTime, end)
        return capped
    }
    let contents = MarkdownRenderer().renderMarkdown(session: session, rows: kept)
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
}

func transcriptMarkdownURL(for session: RecordingSession) -> URL {
    URL(fileURLWithPath: session.micAudioURL)
        .deletingLastPathComponent()
        .appendingPathComponent("transcript.md")
}

/// A live segment's row, under its source: speakers are not known until the recording stops.
private func liveRow(for segment: RecordingTranscriptSegment) -> MarkdownRenderer.Row {
    MarkdownRenderer.Row(
        label: sourceLabel(segment.audioSource),
        text: segment.text,
        startTime: segment.startTime,
        endTime: segment.endTime
    )
}

/// The source names the live recording view shows.
private func sourceLabel(_ source: AudioSource) -> String {
    source == .mic ? "Mic" : "App"
}

/// Brings every recording's `transcript.md` to the current format, once per format version.
enum TranscriptMarkdownRegeneration {
    /// Raised when the format changes, so files written in an older one are rewritten.
    static let currentFormatVersion = 2
    static let formatVersionKey = "transcriptMarkdownFormatVersion"

    /// Rewrites the file of every recording that is not being recorded, when the stored version is
    /// older than the current one. The version is stored only when every write succeeded, so a
    /// failure is retried at the next launch.
    /// - Returns: the number of sessions considered; one with nothing to list gets no file.
    @discardableResult
    static func regenerateIfNeeded(in context: ModelContext, userDefaults: UserDefaults) throws -> Int {
        guard userDefaults.integer(forKey: formatVersionKey) < currentFormatVersion else { return 0 }
        let sessions = try context.fetch(FetchDescriptor<RecordingSession>())
            .filter { $0.status != .recording }
        var firstError: Error?
        for session in sessions {
            do {
                try writeTranscriptMarkdown(for: session)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
        userDefaults.set(currentFormatVersion, forKey: formatVersionKey)
        return sessions.count
    }
}
