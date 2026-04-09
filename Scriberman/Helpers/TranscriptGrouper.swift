import Foundation

enum TranscriptGrouper {
    private static let fallbackSpeakerColor = "#6B7280"

    static func makeBlocks(from transcript: Transcript) -> [TranscriptBlock] {
        guard transcript.segments.isEmpty == false else { return [] }

        let speakersByID = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0) })
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
                    text: mergedText
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
                        text: normalizedText
                    )
                )
            }
        }

        return blocks
    }

    private static func normalizeText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
