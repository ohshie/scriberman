import Foundation

/// The pauses of one recording, in raw host time, and the mapping from raw to adjusted time.
///
/// A raw time is nil inside a pause and at or after the close. Any other raw time loses the length
/// of every pause that ended before it. Every pause is kept, because a buffer captured before a
/// pause can be delivered after it.
struct RecordingPauseTimeline: Sendable {
    /// Consecutive frames of one buffer that are kept, and the paused time removed before them.
    struct KeptRange: Equatable, Sendable {
        let frames: Range<Int>
        let removedNanos: UInt64
    }

    fileprivate struct Pause: Sendable {
        let start: UInt64
        var end: UInt64?
    }

    fileprivate var pauses: [Pause] = []
    fileprivate var closedAt: UInt64?

    var hasPauses: Bool { !pauses.isEmpty }

    /// True while nothing can be cut: no pause so far and not closed.
    var admitsEverything: Bool { pauses.isEmpty && closedAt == nil }

    /// True from a pause until its resume. A recording stopped while paused stays paused.
    var isPaused: Bool {
        guard let last = pauses.last else { return false }
        return last.end == nil
    }

    /// Raw time without the pauses before it, or nil when the time is not part of the recording.
    func adjusted(_ raw: HostNanoseconds) -> HostNanoseconds? {
        let time = raw.nanoseconds
        if let closedAt, time >= closedAt { return nil }
        var removed: UInt64 = 0
        for pause in pauses where pause.start <= time {
            guard let end = pause.end, end <= time else { return nil }
            removed += end - pause.start
        }
        return HostNanoseconds(nanoseconds: time - removed)
    }

    /// For a raw time inside a pause, the adjusted time at which that pause ends. Nil for a time
    /// outside every pause or at or after the close.
    func adjustedResumeTime(forPaused raw: HostNanoseconds) -> HostNanoseconds? {
        let time = raw.nanoseconds
        if let closedAt, time >= closedAt { return nil }
        var removed: UInt64 = 0
        for pause in pauses where pause.start <= time {
            guard let end = pause.end, end <= time else {
                return HostNanoseconds(nanoseconds: pause.start - removed)
            }
            removed += end - pause.start
        }
        return nil
    }

    /// The close in adjusted time: the close without the pauses before it, or the start of the
    /// pause it fell in. Nil while the clock is open.
    var adjustedCloseTime: HostNanoseconds? {
        guard let closedAt else { return nil }
        var removed: UInt64 = 0
        for pause in pauses where pause.start <= closedAt {
            guard let end = pause.end, end <= closedAt else {
                return HostNanoseconds(nanoseconds: pause.start - removed)
            }
            removed += end - pause.start
        }
        return HostNanoseconds(nanoseconds: closedAt - removed)
    }

    /// Paused seconds before `time`. An open pause counts up to `time`, or up to the close.
    func pausedSeconds(until time: HostNanoseconds) -> Double {
        let limit = min(time.nanoseconds, closedAt ?? .max)
        let nanos = pauses.reduce(UInt64(0)) { total, pause in
            let end = min(pause.end ?? limit, limit)
            return total + (end > pause.start ? end - pause.start : 0)
        }
        return Double(nanos) / 1_000_000_000
    }

    /// The frames of a buffer that were captured outside every pause and before the close.
    ///
    /// A frame is paused when its own capture time is in `[pause, resume)`.
    func keptRanges(startNanos: Int64, frameCount: Int, sampleRate: Double) -> [KeptRange] {
        guard frameCount > 0, sampleRate > 0 else { return [] }

        /// First frame captured at or after `time`.
        func frame(at time: UInt64) -> Int {
            let position = Double(Int64(clamping: time) - startNanos) * sampleRate / 1_000_000_000
            // Host times are whole Mach ticks or nanoseconds, so a frame that lies on a boundary
            // can read up to a tick (0.002 frames) after it.
            return Int((position - 0.01).rounded(.up).clamped(to: 0...Double(frameCount)))
        }

        var ranges: [KeptRange] = []
        var cursor = 0
        var removed: UInt64 = 0
        func keep(upTo end: Int) {
            guard end > cursor else { return }
            ranges.append(KeptRange(frames: cursor..<end, removedNanos: removed))
        }

        let limit = closedAt.map(frame(at:)) ?? frameCount
        for pause in pauses {
            keep(upTo: min(frame(at: pause.start), limit))
            guard let end = pause.end else { return ranges }
            cursor = max(cursor, frame(at: end))
            removed += end - pause.start
        }
        keep(upTo: limit)
        return ranges
    }
}

/// The pause clock of one recording, shared by every capture source and kept across capture
/// restarts, as `LiveCaptureClock` is.
///
/// The times passed to `pause`, `resume` and `close` are read under the clock's lock, so no
/// callback can pass audio captured after a boundary that is being set.
///
/// @unchecked Sendable: state is guarded by `lock`.
final class RecordingPauseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var state = RecordingPauseTimeline()

    /// The pauses so far. A buffer is cut against one snapshot.
    var timeline: RecordingPauseTimeline {
        lock.withLock { state }
    }

    var isPaused: Bool { timeline.isPaused }
    var hasPauses: Bool { timeline.hasPauses }

    func adjusted(_ raw: HostNanoseconds) -> HostNanoseconds? {
        timeline.adjusted(raw)
    }

    func pausedSeconds(until time: HostNanoseconds) -> Double {
        timeline.pausedSeconds(until: time)
    }

    /// Starts a pause. False when one is open or the clock is closed.
    @discardableResult
    func pause(at time: () -> HostNanoseconds) -> Bool {
        lock.withLock {
            guard state.closedAt == nil, !state.isPaused else { return false }
            let start = max(time().nanoseconds, state.pauses.last?.end ?? 0)
            state.pauses.append(.init(start: start, end: nil))
            return true
        }
    }

    /// Ends the open pause. False when none is open or the clock is closed.
    @discardableResult
    func resume(at time: () -> HostNanoseconds) -> Bool {
        lock.withLock {
            guard state.closedAt == nil, state.isPaused, let index = state.pauses.indices.last else { return false }
            state.pauses[index].end = max(time().nanoseconds, state.pauses[index].start)
            return true
        }
    }

    /// Ends the recording for good. Nothing captured at or after this time is admitted. An open
    /// pause is never ended. Only the first call counts.
    func close(at time: () -> HostNanoseconds) {
        lock.withLock {
            guard state.closedAt == nil else { return }
            state.closedAt = time().nanoseconds
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
