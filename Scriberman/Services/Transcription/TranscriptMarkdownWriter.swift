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

/// Rewrites `transcript.md` from the session's persisted live segments that start before `end`,
/// capping a segment that runs past it; `nil` writes every segment. Trim and restore call this so
/// the file describes the same range as the audio. A session with no persisted segments never had
/// the file written during capture, so it is left alone.
func rewriteTranscriptMarkdown(for session: RecordingSession, end: Float? = nil) {
    let segments = session.transcriptSegments.sorted { $0.createdAt < $1.createdAt }
    guard !segments.isEmpty else { return }

    let lines = segments.compactMap { segment -> String? in
        guard let end else { return transcriptMarkdownLine(for: segment) }
        guard segment.startTime < end else { return nil }
        return transcriptMarkdownLine(
            speakerId: segment.speakerId,
            text: segment.text,
            startTime: segment.startTime,
            endTime: min(segment.endTime, end)
        )
    }
    let contents = "# Transcript\n\n" + lines.joined()
    try? contents.write(to: transcriptMarkdownURL(for: session), atomically: true, encoding: .utf8)
}

func transcriptMarkdownURL(for session: RecordingSession) -> URL {
    URL(fileURLWithPath: session.micAudioURL)
        .deletingLastPathComponent()
        .appendingPathComponent("transcript.md")
}

private func transcriptMarkdownLine(for segment: RecordingTranscriptSegment) -> String {
    transcriptMarkdownLine(
        speakerId: segment.speakerId,
        text: segment.text,
        startTime: segment.startTime,
        endTime: segment.endTime
    )
}

private func transcriptMarkdownLine(speakerId: String, text: String, startTime: Float, endTime: Float) -> String {
    "[\(formatTranscriptTimestamp(startTime))-\(formatTranscriptTimestamp(endTime))] \(speakerId): \(text)\n"
}

func formatTranscriptTimestamp(_ seconds: Float) -> String {
    String(format: "%.2f", max(0, seconds))
}
