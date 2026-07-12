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
            if sortedDiarized.isEmpty {
                // ASR produced words but the diarizer produced nothing:
                // emit everything as a single-speaker segment spanning the words.
                let text = tokenStitcher.stitchTokens(cleanedWords.map(\.text))
                mappedSegments = text.isEmpty
                    ? []
                    : [
                        TranscriptSegment(
                            speakerId: "S1",
                            text: text,
                            startTime: cleanedWords[0].start,
                            endTime: cleanedWords[cleanedWords.count - 1].end,
                            audioSource: source
                        )
                    ]
            } else {
                // Each word lands in exactly one diarized segment: the one
                // containing its midpoint, else the largest-overlap segment,
                // else (diarization gap) the nearest segment by time distance.
                // Insertion order preserves ASR token order within a bucket.
                var buckets: [[TimedWord]] = Array(repeating: [], count: sortedDiarized.count)
                for word in cleanedWords {
                    buckets[bucketIndex(for: word, in: sortedDiarized)].append(word)
                }
                mappedSegments = zip(sortedDiarized, buckets).compactMap { segment, words in
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

    /// The single diarized segment a word belongs to. `segments` must be
    /// non-empty and sorted by start time.
    private func bucketIndex(for word: TimedWord, in segments: [TimedSpeakerSegment]) -> Int {
        let midpoint = (word.start + word.end) / 2

        if let index = segments.firstIndex(where: {
            midpoint >= $0.startTimeSeconds && midpoint < $0.endTimeSeconds
        }) {
            return index
        }

        var bestOverlap: (index: Int, duration: Float)?
        for (index, segment) in segments.enumerated() {
            let overlap = min(word.end, segment.endTimeSeconds) - max(word.start, segment.startTimeSeconds)
            if overlap > 0, overlap > (bestOverlap?.duration ?? 0) {
                bestOverlap = (index, overlap)
            }
        }
        if let bestOverlap {
            return bestOverlap.index
        }

        // Diarization gap: nearest segment by midpoint distance, earlier on ties.
        var nearest = (index: 0, distance: Float.greatestFiniteMagnitude)
        for (index, segment) in segments.enumerated() {
            let distance = max(segment.startTimeSeconds - midpoint, midpoint - segment.endTimeSeconds, 0)
            if distance < nearest.distance {
                nearest = (index, distance)
            }
        }
        return nearest.index
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
