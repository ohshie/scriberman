import Foundation

func appendTranscriptSegmentToMarkdown(
    _ segment: RecordingTranscriptSegment,
    for session: RecordingSession,
    fileManager: FileManager = .default
) {
    let sessionFolderURL = URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
    let transcriptMarkdownURL = sessionFolderURL.appendingPathComponent("transcript.md")
    let line = "[\(formatTranscriptTimestamp(segment.startTime))-\(formatTranscriptTimestamp(segment.endTime))] \(segment.speakerId): \(segment.text)\n"

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

func formatTranscriptTimestamp(_ seconds: Float) -> String {
    String(format: "%.2f", max(0, seconds))
}
