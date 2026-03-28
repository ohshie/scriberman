import Foundation

struct MarkdownRenderer {
    func renderMarkdown(session: any TranscribableSession, transcript: Transcript) -> String {
        var lines: [String] = []
        lines.append("# \(session.title)")
        lines.append("")
        lines.append("Date: \(dateText(session.createdAt))")
        lines.append("Duration: \(durationText(session.duration))")
        lines.append("")

        let speakersById = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0) })
        let orderedSegments = transcript.segments.sorted { $0.startTime < $1.startTime }

        for segment in orderedSegments {
            let speakerLabel = speakersById[segment.speakerId]?.label ?? "Speaker"
            let rangeText = "\(TimeFormatter.format(seconds: segment.startTime)) – \(TimeFormatter.format(seconds: segment.endTime))"
            lines.append("**\(speakerLabel)** [\(rangeText)]")
            lines.append(segment.text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
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
