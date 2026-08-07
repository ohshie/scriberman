import Foundation

/// One written capture buffer: the host time of its first frame (nanoseconds) and
/// the number of frames written for it. The concatenation of all segments' frames
/// equals the capture file's sample count, so a file can be re-placed onto a real-time
/// timeline from its file samples + segment log.
struct AudioCaptureSegment: Codable, Equatable, Sendable {
    let startHostTimeNanos: UInt64
    let frameCount: Int
}

/// Persisted per-source timing sidecar written next to a capture WAV (`<wav>.timing`).
struct CaptureTimingSidecar: Codable, Sendable {
    let sampleRate: Double
    let segments: [AudioCaptureSegment]

    /// Sum of all segment frame counts (should equal the audio file's sample count).
    var totalFrames: Int { segments.reduce(0) { $0 + $1.frameCount } }
}

/// Converts a mach host-time value to nanoseconds using the system timebase. On
/// Apple Silicon the timebase is 1/1 (host units already are nanoseconds); this stays
/// correct on any timebase.
enum HostClock {
    static func nanoseconds(machTime: UInt64) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        if info.numer == info.denom || info.denom == 0 {
            return machTime
        }
        // Use 128-bit-safe scaling to avoid overflow on long uptimes.
        let numer = UInt64(info.numer)
        let denom = UInt64(info.denom)
        let whole = machTime / denom * numer
        let remainder = machTime % denom * numer / denom
        return whole + remainder
    }
}

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
    /// Frames trimmed from buffers that arrived "early" (source producing more frames than
    /// wall-clock time allows, e.g. duplicated samples upstream) — tracked for diagnostics.
    private(set) var overlapFrames: Int = 0

    /// - Parameter referenceTime: when provided, frame 0 is anchored to this time and
    ///   `append` will not re-anchor to the first buffer — used to place multiple sources
    ///   against one shared reference (so a later-starting source gets leading silence).
    init(sampleRate: Double, referenceTime: Double? = nil) {
        self.sampleRate = sampleRate
        self.referenceTime = referenceTime
    }

    /// Rebuilds a source's real-time timeline from its concatenated file samples and its
    /// segment log, anchored so that `referenceHostTimeNanos` maps to frame 0. Gaps and
    /// capture outages between segments become silence. Segments whose samples exceed the
    /// available buffer are skipped defensively.
    static func reconstruct(
        samples: [Float],
        segments: [AudioCaptureSegment],
        referenceHostTimeNanos: UInt64,
        sampleRate: Double
    ) -> SynchronizedAudioTimeline {
        var timeline = SynchronizedAudioTimeline(sampleRate: sampleRate, referenceTime: 0)
        var offset = 0
        for segment in segments {
            let end = offset + segment.frameCount
            guard segment.frameCount > 0, end <= samples.count else { break }
            let slice = Array(samples[offset..<end])
            let relativeSeconds =
                (Double(segment.startHostTimeNanos) - Double(referenceHostTimeNanos)) / 1_000_000_000.0
            timeline.append(samples: slice, at: relativeSeconds)
            offset = end
        }
        return timeline
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
            frames.append(contentsOf: samples)
            return
        }

        if expected < frames.count {
            // Source delivered more frames than wall-clock time allows (e.g. duplicated
            // samples upstream, or a fast source clock). Trim the overlapping head so the
            // timeline stays anchored to real time instead of accumulating the surplus.
            // Occasional 1–2 frame trims from timestamp jitter are inaudible; a systematic
            // surplus (the failure mode this guards against) is corrected buffer by buffer.
            let overlap = frames.count - expected
            overlapFrames += min(overlap, samples.count)
            guard overlap < samples.count else {
                return // entire buffer is duplicate-in-time; drop it
            }
            frames.append(contentsOf: samples[overlap...])
            return
        }

        frames.append(contentsOf: samples)
    }

    /// Seconds of silence inserted so far.
    var insertedSilenceSeconds: Double {
        Double(insertedSilenceFrames) / sampleRate
    }
}
