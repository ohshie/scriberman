import Foundation

/// Decides whether a recording that reported a successful start is actually writing audio.
///
/// Pure and synchronous: it takes the frame counts already gathered by
/// `RecordingService.captureFrameCounts()` and returns a verdict. It owns no timers, touches no
/// capture, and performs no I/O, so every branch is directly testable.
///
/// The counts are frames written, never audio levels. Frames are produced at the capture sample
/// rate whether or not anyone is speaking, so a recording started in a silent room is healthy.
/// Levels and last-activity timestamps both require sound above a floor and would tear down a
/// recording whose owner simply had not started talking yet.
enum RecordingStartVerifier {
    enum Verdict: Equatable {
        /// At least the microphone is writing. The recording is left alone.
        case healthy
        /// Nothing is being written by any source. The only case that triggers retry and failure.
        case dead
        /// The microphone count is unavailable because the `AVAudioRecorder` fallback is active,
        /// which does not write through `AudioFileStreamer`. Treated as healthy: an unavailable
        /// count is not evidence of failure.
        case unverifiable
    }

    /// - Parameters:
    ///   - micFrames: frames written by the microphone source, or `nil` when unavailable.
    ///   - appFrames: frames written by the app source, or `nil` when app audio is not captured.
    ///
    /// App audio deliberately cannot produce a `dead` verdict on its own. An application that has
    /// not yet activated an audio session legitimately writes nothing, and the common sequence is
    /// to start recording and *then* join the call — so a zero app count in the first seconds is
    /// expected, not broken. Whether app audio ever arrived is settled at stop instead.
    static func verdict(micFrames: Int64?, appFrames: Int64?) -> Verdict {
        guard let micFrames else {
            return .unverifiable
        }
        if micFrames > 0 {
            return .healthy
        }
        if let appFrames, appFrames > 0 {
            // The microphone is dead but app audio is arriving. Still a recording worth keeping —
            // the other side of the call is being captured — so it is not a failed start.
            return .healthy
        }
        return .dead
    }

    /// Whether a stopped recording should be finalized as microphone-only because its app source
    /// never produced audio.
    ///
    /// Deliberately a *stop-time* decision. During the first seconds a zero count is expected —
    /// an application that has not yet activated an audio session writes nothing, and the usual
    /// sequence is to start recording and then join the call. Acting on it early would discard app
    /// audio for the whole meeting to correct a failure that had not happened.
    ///
    /// - Parameter appFrames: frames written by the app source, or `nil` when app audio was not
    ///   being captured at all — in which case there is nothing to degrade.
    static func shouldFinalizeWithoutAppAudio(appFrames: Int64?) -> Bool {
        guard let appFrames else { return false }
        return appFrames == 0
    }

    /// How much of a recording a source has to cover before it is considered complete.
    ///
    /// Grouped as one rule rather than loose constants because the two values only make sense
    /// together: the ratio is what "materially incomplete" means, and the floor is what stops a
    /// short recording tripping on an ordinary lead-in.
    ///
    /// Neither is a correctness boundary. They are a judgement about what is worth telling someone,
    /// and both are deliberately generous — a recording legitimately starts before its owner joins
    /// a call, which is the same reason app audio is never judged during a recording's first
    /// seconds.
    enum SourceCoverageRule {
        /// Below this fraction of the recording's duration, a source counts as incomplete.
        static let minimumCoveredFraction: Double = 0.75
        /// ...but only once this much of the recording is actually missing, so a 20-second lead-in
        /// on a 60-second recording is not reported as a fault.
        static let minimumUncoveredSeconds: TimeInterval = 30
    }

    /// The fraction of `duration` that a source's written frames account for.
    ///
    /// Returns `nil` when the source was not captured, or when the recording has no duration to
    /// measure against. Values above 1 are possible from rounding on very short recordings and are
    /// clamped, since "more than complete" is still complete.
    static func sourceCoverage(
        frames: Int64?,
        duration: TimeInterval,
        sampleRate: Double = 48_000
    ) -> Double? {
        guard let frames, duration > 0, sampleRate > 0 else { return nil }
        let expected = duration * sampleRate
        guard expected > 0 else { return nil }
        return min(1, Double(frames) / expected)
    }

    /// Whether a source covered materially less of the recording than the recording ran, and should
    /// therefore be marked.
    ///
    /// Zero coverage is the limiting case of the same rule: a source that never produced audio is
    /// the extreme of one that stopped early. `shouldFinalizeWithoutAppAudio` continues to own what
    /// *happens* at zero — the recording is finalized as microphone-only — while this decides what
    /// is *reported*.
    static func isSourcePartiallyCovered(
        frames: Int64?,
        duration: TimeInterval,
        sampleRate: Double = 48_000
    ) -> Bool {
        guard let coverage = sourceCoverage(frames: frames, duration: duration, sampleRate: sampleRate) else {
            return false
        }
        guard coverage < SourceCoverageRule.minimumCoveredFraction else { return false }
        let uncoveredSeconds = duration * (1 - coverage)
        return uncoveredSeconds >= SourceCoverageRule.minimumUncoveredSeconds
    }
}
