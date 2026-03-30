import FluidAudio
import Foundation
import OSLog

struct TranscriptAligner {
    private let tokenStitcher = TokenStitcher()
    private let logger = Logger(subsystem: "Scriberman", category: "TranscriptAligner")

    func alignTranscript(
        fullText: String,
        tokenTimings: [TokenTiming],
        diarizedSegments: [TimedSpeakerSegment],
        source: AudioSource
    ) -> Transcript {
        let cleanedWords = tokenTimings.compactMap { timing -> TimedWord? in
            let tokenPiece = tokenStitcher.normalizeTokenPiece(timing.token)
            guard !tokenPiece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TimedWord(text: tokenPiece, start: Float(timing.startTime), end: Float(timing.endTime))
        }

        let sortedDiarized = diarizedSegments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        let mappedSegments: [TranscriptSegment]

        if !cleanedWords.isEmpty {
            mappedSegments = sortedDiarized.compactMap { segment in
                let words = cleanedWords.filter {
                    $0.end > segment.startTimeSeconds && $0.start < segment.endTimeSeconds
                }
                let text = tokenStitcher.stitchTokens(words.map(\.text))
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    speakerId: segment.speakerId,
                    text: text,
                    startTime: segment.startTimeSeconds,
                    endTime: segment.endTimeSeconds,
                    audioSource: source
                )
            }
        } else {
            logger.warning("tokenTimings is empty — falling back to coarse alignment")
            if sortedDiarized.isEmpty {
                mappedSegments = fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? []
                    : [
                        TranscriptSegment(
                            speakerId: "S1",
                            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
                            startTime: 0,
                            endTime: Float(max(0, fullText.count / 12)),
                            audioSource: source
                        )
                    ]
            } else {
                let trimmedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                mappedSegments = trimmedText.isEmpty
                    ? []
                    : [
                        TranscriptSegment(
                            speakerId: sortedDiarized[0].speakerId,
                            text: trimmedText,
                            startTime: sortedDiarized[0].startTimeSeconds,
                            endTime: sortedDiarized.last?.endTimeSeconds ?? sortedDiarized[0].endTimeSeconds,
                            audioSource: source
                        )
                    ]
            }
        }

        let speakerIds = Array(Set(mappedSegments.map(\.speakerId))).sorted()
        let speakers = speakerIds.enumerated().map { index, speakerId in
            TranscriptSpeaker(
                id: speakerId,
                label: "Speaker \(index + 1)",
                colorHex: speakerColorHex(at: index)
            )
        }

        let normalizedFullText: String
        if mappedSegments.isEmpty {
            normalizedFullText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            normalizedFullText = mappedSegments.map(\.text).joined(separator: " ")
        }

        return Transcript(
            fullText: normalizedFullText,
            segments: mappedSegments,
            speakers: speakers
        )
    }

    func speakerColorHex(at index: Int) -> String {
        let palette = ["#4F46E5", "#16A34A", "#EA580C", "#0891B2", "#DC2626", "#7C3AED"]
        return palette[index % palette.count]
    }
}

private struct TimedWord {
    let text: String
    let start: Float
    let end: Float
}
