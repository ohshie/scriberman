import FluidAudio
import Foundation

/// One speaker's contiguous activity in a turn diarizer's committed output.
/// Times are session-clock seconds (same clock as `TranscriptSegment.startTime`).
struct TurnSegment: Equatable, Sendable {
    let speakerIndex: Int
    let start: Float
    let end: Float
}

/// Speaker segments built incrementally from a streaming turn diarizer's
/// committed probability frames (`[frameCount × numSpeakers]`, frame-major).
///
/// A speaker is active in a frame when its probability exceeds
/// `activityThreshold`; runs shorter than `minimumSegmentDuration` are dropped.
/// Both defaults match `Nemotron3Diarizer.segments`. Only runs are kept, not the
/// probabilities, so memory stays flat over a long session.
struct TurnTimeline {
    let numSpeakers: Int
    let frameSeconds: Float
    let activityThreshold: Float
    let minimumSegmentDuration: Float

    private(set) var committedFrameCount = 0
    private var openRunStartFrames: [Int?]
    private var closedSegments: [TurnSegment] = []

    init(
        numSpeakers: Int,
        frameSeconds: Float,
        activityThreshold: Float = 0.5,
        minimumSegmentDuration: Float = 0.2
    ) {
        self.numSpeakers = numSpeakers
        self.frameSeconds = frameSeconds
        self.activityThreshold = activityThreshold
        self.minimumSegmentDuration = minimumSegmentDuration
        self.openRunStartFrames = Array(repeating: nil, count: numSpeakers)
    }

    /// Session seconds up to which the diarizer has committed output.
    var coveredUntil: Float { Float(committedFrameCount) * frameSeconds }

    mutating func append(probabilities: [Float], frameCount: Int) {
        guard frameCount > 0, probabilities.count >= frameCount * numSpeakers else { return }
        for localFrame in 0..<frameCount {
            let frame = committedFrameCount + localFrame
            for speaker in 0..<numSpeakers {
                let isActive = probabilities[localFrame * numSpeakers + speaker] > activityThreshold
                if isActive, openRunStartFrames[speaker] == nil {
                    openRunStartFrames[speaker] = frame
                } else if !isActive, let startFrame = openRunStartFrames[speaker] {
                    closeRun(speaker: speaker, startFrame: startFrame, endFrame: frame)
                    openRunStartFrames[speaker] = nil
                }
            }
        }
        committedFrameCount += frameCount
    }

    /// Closed runs plus runs still open at the committed edge, ordered by start.
    var segments: [TurnSegment] {
        var result = closedSegments
        for speaker in 0..<numSpeakers {
            guard let startFrame = openRunStartFrames[speaker],
                  let segment = segment(speaker: speaker, startFrame: startFrame, endFrame: committedFrameCount)
            else { continue }
            result.append(segment)
        }
        return result.sorted { ($0.start, $0.speakerIndex) < ($1.start, $1.speakerIndex) }
    }

    private mutating func closeRun(speaker: Int, startFrame: Int, endFrame: Int) {
        if let segment = segment(speaker: speaker, startFrame: startFrame, endFrame: endFrame) {
            closedSegments.append(segment)
        }
    }

    private func segment(speaker: Int, startFrame: Int, endFrame: Int) -> TurnSegment? {
        let start = Float(startFrame) * frameSeconds
        let end = Float(endFrame) * frameSeconds
        guard end - start >= minimumSegmentDuration else { return nil }
        return TurnSegment(speakerIndex: speaker, start: start, end: end)
    }
}

/// A contiguous stretch of one turn-diarizer speaker inside a queried time range,
/// clipped to that range. Times are session-clock seconds (same clock as
/// `TranscriptSegment.startTime`).
struct SpeakerRun: Equatable {
    let speakerIndex: Int
    let start: Float
    let end: Float

    var duration: Float { end - start }
}

/// Pure queries over turn-diarizer segments. Kept free of diarizer state so
/// attribution logic is unit-testable with hand-built segments.
enum LiveSpeakerTimeline {
    /// Same-speaker segments closer than this are merged into one run: short
    /// gaps are quantization noise, not speaker turns. Tuned for LS-EEND's 100ms
    /// frames; revisit against recordings for Nemotron 3's 10ms frames.
    private static let mergeGapTolerance: Float = 0.15

    /// Speaker runs (finalized + tentative segments alike) overlapping
    /// `[start, end]`, clipped to the range. Adjacent or overlapping
    /// same-speaker segments are merged, even when another speaker's run starts
    /// between them; the result is ordered by start time.
    static func speakerRuns(in segments: [TurnSegment], start: Float, end: Float) -> [SpeakerRun] {
        guard end > start else { return [] }

        let clipped: [SpeakerRun] = segments.compactMap { segment in
            let clippedStart = max(segment.start, start)
            let clippedEnd = min(segment.end, end)
            guard clippedEnd > clippedStart else { return nil }
            return SpeakerRun(speakerIndex: segment.speakerIndex, start: clippedStart, end: clippedEnd)
        }

        var merged: [SpeakerRun] = []
        for speakerRuns in Dictionary(grouping: clipped, by: \.speakerIndex).values {
            var speakerMerged: [SpeakerRun] = []
            for run in speakerRuns.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
                if let last = speakerMerged.last, run.start - last.end <= mergeGapTolerance {
                    speakerMerged[speakerMerged.count - 1] = SpeakerRun(
                        speakerIndex: last.speakerIndex,
                        start: last.start,
                        end: max(last.end, run.end)
                    )
                } else {
                    speakerMerged.append(run)
                }
            }
            merged.append(contentsOf: speakerMerged)
        }
        return merged.sorted { ($0.start, $0.end, $0.speakerIndex) < ($1.start, $1.end, $1.speakerIndex) }
    }

    /// The speaker with the longest total speech overlapping `[start, end]`,
    /// or nil when the timeline has no data for the range. Ties break toward
    /// the lower speaker index for determinism.
    static func dominantSpeaker(in segments: [TurnSegment], start: Float, end: Float) -> Int? {
        var overlapBySpeaker: [Int: Float] = [:]
        for segment in segments {
            let overlap = min(segment.end, end) - max(segment.start, start)
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

/// Splits a transcribed buffer at turn-diarizer speaker-turn boundaries (design D4).
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
    /// - Otherwise → the buffer is cut at every qualifying run's start and end.
    ///   Each interval belongs to the active run that started most recently, so
    ///   an interjection inside a longer run takes the interval and hands it
    ///   back when it ends. Intervals with no active run split at their
    ///   midpoint between the owners on either side. Parts shorter than
    ///   `minimumRunDuration` dissolve into their longer neighbor, and parts
    ///   tile the buffer even when runs overlap.
    static func planParts(runs: [SpeakerRun], start: Float, end: Float) -> [SegmentPart] {
        guard !runs.isEmpty, end > start else { return [] }

        let qualifying = runs.filter { $0.duration >= minimumRunDuration }
        guard Set(qualifying.map(\.speakerIndex)).count >= 2 else {
            guard let speaker = LiveSpeakerTimeline.dominantSpeaker(among: runs) else { return [] }
            return [SegmentPart(speakerIndex: speaker, start: start, end: end)]
        }

        let boundaries = Set(
            [start, end] + qualifying.flatMap { [$0.start, $0.end] }.filter { $0 > start && $0 < end }
        ).sorted()

        // Owner per elementary interval; nil marks a gap with no active run.
        var intervals: [(speakerIndex: Int?, start: Float, end: Float)] = []
        for (lower, upper) in zip(boundaries, boundaries.dropFirst()) where upper > lower {
            let owner = qualifying
                .filter { $0.start <= lower && $0.end >= upper }
                .max { ($0.start, -$0.speakerIndex) < ($1.start, -$1.speakerIndex) }
            intervals.append((owner?.speakerIndex, lower, upper))
        }

        var parts: [SegmentPart] = []
        for (index, interval) in intervals.enumerated() {
            if let speaker = interval.speakerIndex {
                appendMerging(SegmentPart(speakerIndex: speaker, start: interval.start, end: interval.end), to: &parts)
                continue
            }
            let before = intervals[..<index].last(where: { $0.speakerIndex != nil })?.speakerIndex
            let after = intervals[(index + 1)...].first(where: { $0.speakerIndex != nil })?.speakerIndex
            switch (before, after) {
            case let (before?, after?) where before != after:
                let midpoint = (interval.start + interval.end) / 2
                appendMerging(SegmentPart(speakerIndex: before, start: interval.start, end: midpoint), to: &parts)
                appendMerging(SegmentPart(speakerIndex: after, start: midpoint, end: interval.end), to: &parts)
            case let (speaker?, _), let (nil, speaker?):
                appendMerging(SegmentPart(speakerIndex: speaker, start: interval.start, end: interval.end), to: &parts)
            case (nil, nil):
                continue
            }
        }

        return absorbingShortParts(parts)
    }

    /// Appends `part`, extending the last part instead when it has the same speaker.
    private static func appendMerging(_ part: SegmentPart, to parts: inout [SegmentPart]) {
        guard part.end > part.start else { return }
        if let last = parts.last, last.speakerIndex == part.speakerIndex {
            parts[parts.count - 1] = SegmentPart(speakerIndex: last.speakerIndex, start: last.start, end: part.end)
        } else {
            parts.append(part)
        }
    }

    /// Dissolves parts shorter than `minimumRunDuration` into their longer
    /// neighbor, shortest first, until every part qualifies or one remains.
    private static func absorbingShortParts(_ parts: [SegmentPart]) -> [SegmentPart] {
        var parts = parts
        while parts.count > 1,
              let shortIndex = parts.indices
                  .filter({ parts[$0].duration < minimumRunDuration })
                  .min(by: { parts[$0].duration < parts[$1].duration }) {
            let short = parts[shortIndex]
            let previous = shortIndex > 0 ? parts[shortIndex - 1] : nil
            let next = shortIndex < parts.count - 1 ? parts[shortIndex + 1] : nil
            let absorbIntoPrevious = next == nil || (previous.map { $0.duration >= next!.duration } ?? false)

            var rebuilt: [SegmentPart] = []
            for (index, part) in parts.enumerated() where index != shortIndex {
                if absorbIntoPrevious, index == shortIndex - 1 {
                    appendMerging(SegmentPart(speakerIndex: part.speakerIndex, start: part.start, end: short.end), to: &rebuilt)
                } else if !absorbIntoPrevious, index == shortIndex + 1 {
                    appendMerging(SegmentPart(speakerIndex: part.speakerIndex, start: short.start, end: part.end), to: &rebuilt)
                } else {
                    appendMerging(part, to: &rebuilt)
                }
            }
            parts = rebuilt
        }
        return parts
    }

    /// Apportions `text` across `parts`, returning one string per part
    /// (possibly empty).
    ///
    /// With ASR token timings, tokens group into words (a token with a leading
    /// space opens a word, since FluidAudio turns SentencePiece's word-boundary
    /// marker into a space) and each whole word goes to the part containing its
    /// midpoint, or the nearest part. Each part's text is stitched from its
    /// tokens. Without timings, words split proportionally to part duration.
    static func apportionText(
        _ text: String,
        parts: [SegmentPart],
        bufferStart: Float,
        tokenTimings: [TokenTiming]?
    ) -> [String] {
        guard parts.count > 1 else {
            return parts.isEmpty ? [] : [text]
        }

        let timedWords = words(from: tokenTimings ?? [], bufferStart: bufferStart)
        guard !timedWords.isEmpty else {
            return apportionByDuration(text, parts: parts, bufferStart: bufferStart)
        }

        var piecesByPart: [[String]] = Array(repeating: [], count: parts.count)
        for word in timedWords {
            piecesByPart[partIndex(containing: word.midpoint, in: parts)].append(contentsOf: word.pieces)
        }
        let stitcher = TokenStitcher()
        return piecesByPart.map { stitcher.stitchTokens($0) }
    }

    private struct TimedTokenWord {
        var pieces: [String]
        let start: Float
        var end: Float

        var midpoint: Float { (start + end) / 2 }
    }

    /// Groups buffer-relative token timings into words in session time.
    private static func words(from timings: [TokenTiming], bufferStart: Float) -> [TimedTokenWord] {
        var words: [TimedTokenWord] = []
        for timing in timings {
            let tokenStart = bufferStart + Float(timing.startTime)
            let tokenEnd = bufferStart + Float(timing.endTime)
            let opensWord = timing.token.first.map { $0.isWhitespace || $0 == "▁" } ?? false
            if opensWord || words.isEmpty {
                words.append(TimedTokenWord(pieces: [timing.token], start: tokenStart, end: tokenEnd))
            } else {
                words[words.count - 1].pieces.append(timing.token)
                words[words.count - 1].end = max(words[words.count - 1].end, tokenEnd)
            }
        }
        let stitcher = TokenStitcher()
        return words.filter { !stitcher.stitchTokens($0.pieces).isEmpty }
    }

    /// The part containing `time`, else the nearest part (earlier on ties).
    private static func partIndex(containing time: Float, in parts: [SegmentPart]) -> Int {
        if let index = parts.firstIndex(where: { time >= $0.start && time < $0.end }) {
            return index
        }
        var nearest = (index: 0, distance: Float.greatestFiniteMagnitude)
        for (index, part) in parts.enumerated() {
            let distance = max(part.start - time, time - part.end, 0)
            if distance < nearest.distance {
                nearest = (index, distance)
            }
        }
        return nearest.index
    }

    /// Splits `text`'s words across `parts` in proportion to part duration.
    private static func apportionByDuration(_ text: String, parts: [SegmentPart], bufferStart: Float) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard !words.isEmpty else {
            return Array(repeating: "", count: parts.count)
        }

        let totalDuration = parts[parts.count - 1].end - bufferStart
        var splitIndices: [Int] = []
        var previous = 0
        for part in parts.dropLast() {
            let fraction = totalDuration > 0 ? (part.end - bufferStart) / totalDuration : 0
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

/// Pairs clustering-diarizer embeddings with turn-diarizer speakers by time
/// overlap. Overlap is measured against speaker runs, not against planned
/// parts: a part can absorb another speaker's short turn.
enum LiveEmbeddingAttribution {
    /// Share of a clustering segment's duration that must lie inside one
    /// speaker's runs for its embedding to count as that speaker's voice.
    static let minimumOverlapFraction: Float = 0.8

    struct Assignment {
        let segment: TimedSpeakerSegment
        let overlapFraction: Float
    }

    /// For each turn-diarizer speaker index, the longest clustering segment
    /// that lies inside that speaker's runs. A segment shorter than
    /// `SessionSpeakerIdentity.minimumEmbeddingSeconds`, or that reaches
    /// `minimumOverlapFraction` for no speaker or for several (simultaneous
    /// speech), is discarded. `clusterSegments` are buffer-relative; `runs`
    /// are session time, as returned by `LiveSpeakerTimeline.speakerRuns`.
    static func assignments(
        clusterSegments: [TimedSpeakerSegment],
        runs: [SpeakerRun],
        bufferStart: Float
    ) -> [Int: Assignment] {
        var result: [Int: Assignment] = [:]
        for segment in clusterSegments
        where !segment.embedding.isEmpty && segment.durationSeconds >= SessionSpeakerIdentity.minimumEmbeddingSeconds {
            let start = bufferStart + segment.startTimeSeconds
            let end = bufferStart + segment.endTimeSeconds
            let duration = end - start
            guard duration > 0 else { continue }

            var overlapBySpeaker: [Int: Float] = [:]
            for run in runs {
                let overlap = min(run.end, end) - max(run.start, start)
                if overlap > 0 {
                    overlapBySpeaker[run.speakerIndex, default: 0] += overlap
                }
            }
            let containing = overlapBySpeaker.filter { $0.value / duration >= minimumOverlapFraction }
            guard containing.count == 1, let (speakerIndex, overlap) = containing.first else { continue }

            if let existing = result[speakerIndex], existing.segment.durationSeconds >= segment.durationSeconds {
                continue
            }
            result[speakerIndex] = Assignment(segment: segment, overlapFraction: overlap / duration)
        }
        return result
    }
}
