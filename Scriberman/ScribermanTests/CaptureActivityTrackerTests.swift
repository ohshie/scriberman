import Foundation
import Testing
@testable import Scriberman

struct CaptureActivityTrackerTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    /// Default tuning: floor 0.01, sustained 1.0s, gap tolerance 0.5s.
    private func makeTracker() -> CaptureActivityTracker {
        CaptureActivityTracker()
    }

    /// Feeds `level` every `step` seconds for `duration`, returning the end time.
    private func feed(
        _ tracker: inout CaptureActivityTracker,
        level: Float,
        from start: Date,
        duration: TimeInterval,
        step: TimeInterval = 0.01
    ) -> Date {
        var now = start
        let end = start.addingTimeInterval(duration)
        while now <= end {
            tracker.record(level: level, at: now)
            now = now.addingTimeInterval(step)
        }
        return end
    }

    @Test("No activity is recorded before any audio arrives")
    func startsWithNoActivity() {
        let tracker = makeTracker()
        #expect(tracker.lastActivityAt == nil)
        #expect(tracker.idleDuration(at: base) == nil)
    }

    @Test("Sustained loud audio records activity")
    func sustainedAudioRecordsActivity() {
        var tracker = makeTracker()
        let end = feed(&tracker, level: 0.3, from: base, duration: 2.0)
        #expect(tracker.lastActivityAt != nil)
        // Activity keeps updating while loud, so it lands at the end of the run.
        #expect(tracker.lastActivityAt.map { abs($0.timeIntervalSince(end)) < 0.05 } == true)
    }

    @Test("A brief blip never counts as activity")
    func briefBlipIsIgnored() {
        var tracker = makeTracker()
        // 200 ms chime — well under the 1 s sustained interval.
        _ = feed(&tracker, level: 0.9, from: base, duration: 0.2)
        #expect(tracker.lastActivityAt == nil)
    }

    @Test("Repeated distant blips never accumulate into activity")
    func distantBlipsDoNotAccumulate() {
        var tracker = makeTracker()
        // Three separate 200 ms dings, minutes apart: each starts a fresh run.
        for minute in 0..<3 {
            let start = base.addingTimeInterval(Double(minute) * 60)
            _ = feed(&tracker, level: 0.9, from: start, duration: 0.2)
        }
        #expect(tracker.lastActivityAt == nil)
    }

    @Test("Short quiet dips inside speech do not restart the run")
    func speechGapsDoNotBreakRun() {
        var tracker = makeTracker()
        // Speech pattern: 0.4 s loud, 0.3 s quiet, repeated. Gaps are under the 0.5 s
        // tolerance, so the run should survive and cross the sustained threshold.
        var now = base
        for _ in 0..<4 {
            now = feed(&tracker, level: 0.4, from: now, duration: 0.4)
            now = feed(&tracker, level: 0.0, from: now, duration: 0.3)
        }
        #expect(tracker.lastActivityAt != nil)
    }

    @Test("A long quiet gap restarts the run so a following blip does not count")
    func longGapRestartsRun() {
        var tracker = makeTracker()
        // 0.6 s of audio, then a 5 s silence, then another 0.6 s: neither run reaches 1 s.
        _ = feed(&tracker, level: 0.4, from: base, duration: 0.6)
        let resume = base.addingTimeInterval(5.6)
        _ = feed(&tracker, level: 0.4, from: resume, duration: 0.6)
        #expect(tracker.lastActivityAt == nil)
    }

    @Test("Silent buffers do not advance activity")
    func silentBuffersDoNotAdvance() {
        var tracker = makeTracker()
        let end = feed(&tracker, level: 0.3, from: base, duration: 2.0)
        let recorded = tracker.lastActivityAt

        // Ten seconds of digital silence still arriving as buffers.
        _ = feed(&tracker, level: 0.0, from: end, duration: 10.0)

        #expect(tracker.lastActivityAt == recorded)
        let idle = tracker.idleDuration(at: end.addingTimeInterval(10))
        #expect(idle != nil && idle! >= 9.9)
    }

    @Test("Idle duration grows when buffers stop arriving entirely")
    func idleGrowsWhenBuffersStop() {
        var tracker = makeTracker()
        let end = feed(&tracker, level: 0.3, from: base, duration: 2.0)

        // No further calls at all — the app quit. Idle must still grow with wall clock.
        let idleAfterFiveMinutes = tracker.idleDuration(at: end.addingTimeInterval(300))
        #expect(idleAfterFiveMinutes != nil && idleAfterFiveMinutes! >= 299)
    }

    @Test("Level at or below the floor is not activity")
    func floorIsExclusive() {
        var tracker = makeTracker(  )
        _ = feed(&tracker, level: 0.01, from: base, duration: 5.0)
        #expect(tracker.lastActivityAt == nil)
    }

    @Test("Custom tuning is honoured")
    func customTuning() {
        var tracker = CaptureActivityTracker(levelFloor: 0.5, sustainedInterval: 0.2, gapTolerance: 0.1)
        // Below the custom floor.
        _ = feed(&tracker, level: 0.4, from: base, duration: 2.0)
        #expect(tracker.lastActivityAt == nil)
        // Above it, and past the shorter sustained interval.
        _ = feed(&tracker, level: 0.6, from: base.addingTimeInterval(10), duration: 0.3)
        #expect(tracker.lastActivityAt != nil)
    }
}
