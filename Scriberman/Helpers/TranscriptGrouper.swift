import Foundation

enum TranscriptGrouper {
    private static let fallbackSpeakerColor = "#6B7280"

    static func makeBlocks(from transcript: Transcript) -> [TranscriptBlock] {
        guard transcript.segments.isEmpty == false else { return [] }

        // Colour comes from the speaker's position here rather than from what was stored with it.
        // Every transcript recorded before this was written gave all its speakers one colour, and a
        // conversation drawn in a single colour spends the dot and the coloured label on nothing.
        // Deriving at display time fixes those without rewriting anything on disk.
        let speakersByID = Dictionary(uniqueKeysWithValues: displaySpeakers(of: transcript).map { ($0.id, $0) })
        var blocks: [TranscriptBlock] = []

        for segment in transcript.segments {
            let speaker = speakersByID[segment.speakerId] ?? TranscriptSpeaker(
                id: segment.speakerId,
                label: segment.speakerId,
                colorHex: fallbackSpeakerColor
            )
            let normalizedText = normalizeText(segment.text)

            if var lastBlock = blocks.last,
               lastBlock.speaker.id == segment.speakerId,
               lastBlock.audioSource == segment.audioSource {
                let mergedText = [lastBlock.text, normalizedText]
                    .filter { $0.isEmpty == false }
                    .joined(separator: " ")

                lastBlock = TranscriptBlock(
                    id: lastBlock.id,
                    speaker: lastBlock.speaker,
                    audioSource: lastBlock.audioSource,
                    startTime: lastBlock.startTime,
                    endTime: segment.endTime,
                    text: mergedText,
                    segmentIDs: lastBlock.segmentIDs + [segment.id]
                )
                blocks[blocks.count - 1] = lastBlock
            } else {
                blocks.append(
                    TranscriptBlock(
                        id: segment.id,
                        speaker: speaker,
                        audioSource: segment.audioSource,
                        startTime: segment.startTime,
                        endTime: segment.endTime,
                        text: normalizedText,
                        segmentIDs: [segment.id]
                    )
                )
            }
        }

        return blocks
    }

    /// The transcript's speakers with the colours they are drawn in: each from its position in the
    /// speaker list.
    static func displaySpeakers(of transcript: Transcript) -> [TranscriptSpeaker] {
        transcript.speakers.enumerated().map { index, speaker in
            TranscriptSpeaker(id: speaker.id, label: speaker.label, colorHex: SpeakerPalette.colorHex(at: index))
        }
    }

    private static func normalizeText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
