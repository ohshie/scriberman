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
}
