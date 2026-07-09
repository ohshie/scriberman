import FluidAudio
import Foundation

/// A contiguous stretch of one LS-EEND speaker inside a queried time range,
/// clipped to that range. Times are session-clock seconds (same clock as
/// `TranscriptSegment.startTime`).
struct SpeakerRun: Equatable {
    let speakerIndex: Int
    let start: Float
    let end: Float

    var duration: Float { end - start }
}

/// Pure queries over LS-EEND `DiarizerTimeline` segments. Kept free of
/// diarizer state so attribution logic is unit-testable with hand-built
/// segments.
enum LiveSpeakerTimeline {
    /// Same-speaker segments closer than this are merged into one run.
    /// LS-EEND emits 100ms frames; one-frame gaps are quantization noise,
    /// not speaker turns.
    private static let mergeGapTolerance: Float = 0.15

    /// Speaker runs (finalized + tentative segments alike) overlapping
    /// `[start, end]`, clipped to the range. Adjacent or overlapping
    /// same-speaker segments are merged; the result is ordered by start time.
    static func speakerRuns(in segments: [DiarizerSegment], start: Float, end: Float) -> [SpeakerRun] {
        guard end > start else { return [] }

        let clipped: [SpeakerRun] = segments.compactMap { segment in
            let clippedStart = max(segment.startTime, start)
            let clippedEnd = min(segment.endTime, end)
            guard clippedEnd > clippedStart else { return nil }
            return SpeakerRun(speakerIndex: segment.speakerIndex, start: clippedStart, end: clippedEnd)
        }
        .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        var merged: [SpeakerRun] = []
        for run in clipped {
            if let last = merged.last,
               last.speakerIndex == run.speakerIndex,
               run.start - last.end <= mergeGapTolerance {
                merged[merged.count - 1] = SpeakerRun(
                    speakerIndex: last.speakerIndex,
                    start: last.start,
                    end: max(last.end, run.end)
                )
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    /// The speaker with the longest total speech overlapping `[start, end]`,
    /// or nil when the timeline has no data for the range. Ties break toward
    /// the lower speaker index for determinism.
    static func dominantSpeaker(in segments: [DiarizerSegment], start: Float, end: Float) -> Int? {
        var overlapBySpeaker: [Int: Float] = [:]
        for segment in segments {
            let overlap = min(segment.endTime, end) - max(segment.startTime, start)
            guard overlap > 0 else { continue }
            overlapBySpeaker[segment.speakerIndex, default: 0] += overlap
        }
        return overlapBySpeaker.max { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value < rhs.value
            }
            return lhs.key > rhs.key
        }?.key
    }

    /// Dominant speaker among already-clipped runs (longest total duration,
    /// ties toward the lower index).
    static func dominantSpeaker(among runs: [SpeakerRun]) -> Int? {
        var durationBySpeaker: [Int: Float] = [:]
        for run in runs where run.duration > 0 {
            durationBySpeaker[run.speakerIndex, default: 0] += run.duration
        }
        return durationBySpeaker.max { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value < rhs.value
            }
            return lhs.key > rhs.key
        }?.key
    }
}

/// One attributed slice of a transcribed buffer. Parts returned by
/// `LiveSegmentSplitter.planParts` are contiguous and non-overlapping and
/// together cover the whole buffer range.
struct SegmentPart: Equatable {
    let speakerIndex: Int
    let start: Float
    let end: Float

    var duration: Float { end - start }
}

/// Splits a transcribed buffer at LS-EEND speaker-turn boundaries (design D4).
enum LiveSegmentSplitter {
    /// Runs shorter than this merge into the adjacent dominant run instead of
    /// splitting the segment (matches Parakeet's ~1s timing reliability floor).
    static let minimumRunDuration: Float = 1.0

    /// Plans attribution for a buffer spanning `[start, end]` session seconds.
    ///
    /// - Empty `runs` → empty result; the caller falls back to
    ///   embedding-based attribution.
    /// - Runs from a single speaker, or from several speakers where fewer
    ///   than two hold runs ≥ `minimumRunDuration` → one part for the whole
    ///   buffer attributed to the dominant speaker.
    /// - Otherwise → one part per qualifying run, split at gap midpoints so
    ///   parts tile the buffer; sub-threshold runs dissolve into whichever
    ///   neighboring part absorbs their time span.
    static func planParts(runs: [SpeakerRun], start: Float, end: Float) -> [SegmentPart] {
        guard !runs.isEmpty, end > start else { return [] }

        var qualifying = runs.filter { $0.duration >= minimumRunDuration }
        // Consecutive qualifying runs of the same speaker act as one turn.
        var collapsed: [SpeakerRun] = []
        for run in qualifying {
            if let last = collapsed.last, last.speakerIndex == run.speakerIndex {
                collapsed[collapsed.count - 1] = SpeakerRun(
                    speakerIndex: last.speakerIndex,
                    start: last.start,
                    end: max(last.end, run.end)
                )
            } else {
                collapsed.append(run)
            }
        }
        qualifying = collapsed

        guard qualifying.count >= 2 else {
            guard let speaker = LiveSpeakerTimeline.dominantSpeaker(among: runs) else { return [] }
            return [SegmentPart(speakerIndex: speaker, start: start, end: end)]
        }

        var parts: [SegmentPart] = []
        for (index, run) in qualifying.enumerated() {
            let partStart = index == 0 ? start : (qualifying[index - 1].end + run.start) / 2
            let partEnd = index == qualifying.count - 1 ? end : (run.end + qualifying[index + 1].start) / 2
            parts.append(SegmentPart(speakerIndex: run.speakerIndex, start: partStart, end: partEnd))
        }
        return parts
    }

    /// Apportions `text` across `parts`. Word boundaries come from ASR token
    /// timings when available (a boundary lands after the fraction of tokens
    /// whose midpoints precede it); otherwise words split proportionally to
    /// part duration. Returns one string per part (possibly empty).
    static func apportionText(
        _ text: String,
        parts: [SegmentPart],
        bufferStart: Float,
        tokenTimings: [TokenTiming]?
    ) -> [String] {
        guard parts.count > 1 else {
            return parts.isEmpty ? [] : [text]
        }

        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard !words.isEmpty else {
            return Array(repeating: "", count: parts.count)
        }

        let totalDuration = parts[parts.count - 1].end - bufferStart
        let timings = tokenTimings ?? []

        // Fraction of the text that precedes each interior part boundary.
        let boundaryFractions: [Float] = parts.dropLast().map { part in
            let boundary = part.end - bufferStart
            if !timings.isEmpty {
                let preceding = timings.filter { Float($0.startTime + $0.endTime) / 2 < boundary }.count
                return Float(preceding) / Float(timings.count)
            }
            guard totalDuration > 0 else { return 0 }
            return boundary / totalDuration
        }

        var splitIndices: [Int] = []
        var previous = 0
        for fraction in boundaryFractions {
            let index = Int((fraction * Float(words.count)).rounded())
            let clamped = min(max(index, previous), words.count)
            splitIndices.append(clamped)
            previous = clamped
        }

        var result: [String] = []
        var lower = 0
        for upper in splitIndices + [words.count] {
            result.append(words[lower..<upper].joined(separator: " "))
            lower = upper
        }
        return result
    }
}
