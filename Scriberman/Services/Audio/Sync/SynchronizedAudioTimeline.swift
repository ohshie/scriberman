import Foundation

/// Places captured audio buffers on a fixed-sample-rate timeline by their
/// presentation time (in seconds) rather than by accumulated sample count.
///
/// Each source anchors frame 0 to the presentation time of its first buffer.
/// Every subsequent buffer is written at `round((pts − reference) × sampleRate)`,
/// with silence inserted for any gap between the current end of the timeline and
/// that expected frame. This keeps a source's sample index mapped to elapsed real
/// (wall-clock) time, which bounds mic↔app drift and makes capture outages
/// self-heal (a gap in presentation time becomes an equal gap of silence).
///
/// This is the pure, unit-testable core used by both the capture-time writer and
/// the mixdown path. It accumulates into an in-memory buffer (same memory profile
/// as the existing whole-file mixdown); a streaming variant can reuse `gapFrames`.
struct SynchronizedAudioTimeline {
    let sampleRate: Double

    private(set) var frames: [Float] = []
    private(set) var referenceTime: Double?
    /// Total silence frames inserted to fill gaps (diagnostics).
    private(set) var insertedSilenceFrames: Int = 0
    /// Number of discontinuities that required gap-fill (diagnostics).
    private(set) var gapCount: Int = 0
    /// Frames that arrived "early" (source running faster than wall clock) and were
    /// appended contiguously instead of overwriting — tracked for diagnostics.
    private(set) var overlapFrames: Int = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Frame index at which a buffer with the given presentation time should start,
    /// relative to the established reference. Returns `nil` before a reference exists.
    func expectedStartFrame(for presentationTime: Double) -> Int? {
        guard let referenceTime else { return nil }
        return max(0, Int(((presentationTime - referenceTime) * sampleRate).rounded()))
    }

    /// Silence frames that must precede `samples` presented at `presentationTime`
    /// to keep the timeline aligned. Non-negative; 0 when contiguous or early.
    func gapFrames(before presentationTime: Double, writtenFrames: Int) -> Int {
        guard let referenceTime else { return 0 }
        let expected = max(0, Int(((presentationTime - referenceTime) * sampleRate).rounded()))
        return max(0, expected - writtenFrames)
    }

    /// Append a buffer captured at `presentationTime` (seconds, monotonic). The first
    /// call establishes the reference (frame 0).
    mutating func append(samples: [Float], at presentationTime: Double) {
        if referenceTime == nil {
            referenceTime = presentationTime
        }

        let expected = expectedStartFrame(for: presentationTime) ?? frames.count
        if expected > frames.count {
            let gap = expected - frames.count
            frames.append(contentsOf: repeatElement(0, count: gap))
            insertedSilenceFrames += gap
            gapCount += 1
        } else if expected < frames.count {
            // Source delivered faster than wall clock; append contiguously rather than
            // overwrite already-written audio. Small and bounded in practice.
            overlapFrames += frames.count - expected
        }

        frames.append(contentsOf: samples)
    }

    /// Seconds of silence inserted so far.
    var insertedSilenceSeconds: Double {
        Double(insertedSilenceFrames) / sampleRate
    }
}
