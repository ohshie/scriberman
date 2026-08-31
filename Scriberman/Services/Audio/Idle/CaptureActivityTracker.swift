import Foundation

/// Tracks when an audio source last produced *sustained* activity, so idleness can be
/// measured from a timestamp rather than from the instantaneous level meter.
///
/// This exists because the level meter cannot be used for silence detection: it is only
/// written when a buffer is written, so a source that stops delivering buffers entirely
/// (the app quit, or released its audio session — the most common way a call ends) leaves
/// the level frozen at its last non-zero reading. A timestamp that simply stops advancing
/// treats "silent buffers" and "no buffers at all" identically, which is what we want.
///
/// Activity requires the level to stay above `levelFloor` for `sustainedInterval`. Short
/// quiet dips shorter than `gapTolerance` do not break a run (speech has gaps between
/// words), but an isolated blip — a notification chime, a single click — never accumulates
/// enough continuous time to count, so it cannot reset a long idle timer.
struct CaptureActivityTracker: Equatable {
    /// RMS level above which audio counts toward an activity run.
    let levelFloor: Float
    /// How long the level must stay above the floor before it counts as activity.
    let sustainedInterval: TimeInterval
    /// Quiet gap tolerated inside a run without restarting it.
    let gapTolerance: TimeInterval

    /// Last moment this source produced sustained activity.
    private(set) var lastActivityAt: Date?

    private var runStartedAt: Date?
    private var lastLoudAt: Date?

    init(
        levelFloor: Float = 0.01,
        sustainedInterval: TimeInterval = 1.0,
        gapTolerance: TimeInterval = 0.5,
        lastActivityAt: Date? = nil
    ) {
        self.levelFloor = levelFloor
        self.sustainedInterval = sustainedInterval
        self.gapTolerance = gapTolerance
        self.lastActivityAt = lastActivityAt
    }

    /// Feed one buffer's measured level. Only call this when a buffer actually arrives —
    /// absence of calls is exactly how idleness is detected.
    mutating func record(level: Float, at now: Date) {
        guard level > levelFloor else {
            // Quiet buffer: leave the run alone. It expires on its own via `gapTolerance`
            // the next time a loud buffer arrives.
            return
        }

        if let lastLoudAt, now.timeIntervalSince(lastLoudAt) <= gapTolerance {
            // Continue the current run through a short dip.
        } else {
            runStartedAt = now
        }
        lastLoudAt = now

        if let runStartedAt, now.timeIntervalSince(runStartedAt) >= sustainedInterval {
            lastActivityAt = now
        }
    }

    /// Seconds since the last sustained activity, measured from `now`. Returns nil when the
    /// source has never been active (callers decide how to treat that).
    func idleDuration(at now: Date) -> TimeInterval? {
        guard let lastActivityAt else { return nil }
        return max(0, now.timeIntervalSince(lastActivityAt))
    }
}
