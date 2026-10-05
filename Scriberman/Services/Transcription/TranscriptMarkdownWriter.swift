import Foundation

func appendTranscriptSegmentToMarkdown(
    _ segment: RecordingTranscriptSegment,
    for session: RecordingSession,
    fileManager: FileManager = .default
) {
    let transcriptMarkdownURL = transcriptMarkdownURL(for: session)
    let line = transcriptMarkdownLine(for: segment)

    if fileManager.fileExists(atPath: transcriptMarkdownURL.path) {
        if let fileHandle = try? FileHandle(forWritingTo: transcriptMarkdownURL) {
            defer { try? fileHandle.close() }
            try? fileHandle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try? fileHandle.write(contentsOf: data)
            }
        }
        return
    }

    let initialContents = "# Transcript\n\n\(line)"
    try? initialContents.write(to: transcriptMarkdownURL, atomically: true, encoding: .utf8)
}

/// Rewrites `transcript.md` to show what the app shows.
///
/// With a saved transcript, the file lists the shown pass (`retranscript ?? transcript`) under each
/// speaker's label, so renames, recognized names and `Speaker N` read the same as in the app.
/// Without one (a recording still in progress or interrupted), it lists the persisted live segments
/// under their source, as the live view does. Segments that start at or after `end` are left out and
/// a segment that runs past it is capped; `nil` writes every segment. Called whenever the shown
/// transcript or its labels change: stop, rename, retranscription, trim and restore. A session with
/// nothing to list is left alone.
func rewriteTranscriptMarkdown(for session: RecordingSession, end: Float? = nil) {
    let rows: [(label: String, text: String, startTime: Float, endTime: Float)]
    if let transcript = session.retranscript ?? session.transcript {
        let labels = Dictionary(transcript.speakers.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        rows = transcript.segments.map { (labels[$0.speakerId] ?? $0.speakerId, $0.text, $0.startTime, $0.endTime) }
    } else {
        rows = session.transcriptSegments
            .sorted { $0.createdAt < $1.createdAt }
            .map { (sourceLabel($0.audioSource), $0.text, $0.startTime, $0.endTime) }
    }
    let fileURL = transcriptMarkdownURL(for: session)
    guard !rows.isEmpty || FileManager.default.fileExists(atPath: fileURL.path) else { return }

    let lines = rows.compactMap { row -> String? in
        guard let end else {
            return transcriptMarkdownLine(label: row.label, text: row.text, startTime: row.startTime, endTime: row.endTime)
        }
        guard row.startTime < end else { return nil }
        return transcriptMarkdownLine(label: row.label, text: row.text, startTime: row.startTime, endTime: min(row.endTime, end))
    }
    let contents = "# Transcript\n\n" + lines.joined()
    try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
}

func transcriptMarkdownURL(for session: RecordingSession) -> URL {
    URL(fileURLWithPath: session.micAudioURL)
        .deletingLastPathComponent()
        .appendingPathComponent("transcript.md")
}

/// A live segment's line, under its source: speakers are not known until the recording stops.
private func transcriptMarkdownLine(for segment: RecordingTranscriptSegment) -> String {
    transcriptMarkdownLine(
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

private func transcriptMarkdownLine(label: String, text: String, startTime: Float, endTime: Float) -> String {
    "[\(formatTranscriptTimestamp(startTime))-\(formatTranscriptTimestamp(endTime))] \(label): \(text)\n"
}

func formatTranscriptTimestamp(_ seconds: Float) -> String {
    String(format: "%.2f", max(0, seconds))
}
