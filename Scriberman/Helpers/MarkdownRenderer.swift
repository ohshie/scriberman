import Foundation

struct MarkdownRenderer {
    /// One passage as the Markdown lists it: under a speaker's label, or under its source while a
    /// recording has no saved transcript.
    struct Row: Equatable {
        var label: String
        var text: String
        var startTime: Float
        var endTime: Float
    }

    func renderMarkdown(session: any TranscribableSession, transcript: Transcript) -> String {
        renderMarkdown(session: session, rows: Self.rows(for: transcript))
    }

    /// The header followed by one block per row, in the order given.
    ///
    /// Copy, export and `transcript.md` all come through here, so the format is defined once.
    func renderMarkdown(session: any TranscribableSession, rows: [Row]) -> String {
        header(for: session) + rows.map(block(for:)).joined()
    }

    /// The title, date and duration that open the document. Blocks are appended after it.
    func header(for session: any TranscribableSession) -> String {
        "# \(session.title)\n\nDate: \(dateText(session.createdAt))\nDuration: \(durationText(session.duration))\n"
    }

    /// One row's block, starting with the blank line that separates it from what precedes it, so
    /// appending blocks to a header yields the same text as rendering them together.
    func block(for row: Row) -> String {
        let rangeText = "\(TimeFormatter.format(seconds: row.startTime)) – \(TimeFormatter.format(seconds: row.endTime))"
        return "\n**\(row.label)** [\(rangeText)]\n\(row.text)\n"
    }

    /// A transcript's segments by start time, each under its speaker's label.
    static func rows(for transcript: Transcript) -> [Row] {
        let speakersById = Dictionary(transcript.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return transcript.segments
            .sorted { $0.startTime < $1.startTime }
            .map { segment in
                Row(
                    label: speakersById[segment.speakerId]?.label ?? "Speaker",
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            }
    }

    func defaultFileName(for title: String) -> String {
        let invalidCharacterSet = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let sanitizedTitle = title.components(separatedBy: invalidCharacterSet).joined(separator: "-")
        let trimmed = sanitizedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Transcript" : trimmed
        return "\(baseName).md"
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func durationText(_ duration: TimeInterval) -> String {
        TimeFormatter.format(seconds: Float(duration))
    }
}
