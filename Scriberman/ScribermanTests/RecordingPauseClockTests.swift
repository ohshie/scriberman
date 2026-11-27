import Foundation
import Testing
@testable import Scriberman

struct RecordingPauseClockTests {
    private func ms(_ value: UInt64) -> HostNanoseconds {
        HostNanoseconds(nanoseconds: value * 1_000_000)
    }

    private func frames(_ clock: RecordingPauseClock, start: UInt64, count: Int = 4_800) -> [Range<Int>] {
        clock.timeline.keptRanges(startNanos: Int64(start) * 1_000_000, frameCount: count, sampleRate: 48_000)
            .map(\.frames)
    }

    @Test
    func timesPassUnchangedWithoutAPause() {
        let clock = RecordingPauseClock()
        #expect(clock.adjusted(ms(1_234)) == ms(1_234))
        #expect(clock.hasPauses == false)
        #expect(frames(clock, start: 1_000) == [0..<4_800])
    }

    @Test
    func mapsBeforeInsideAndAfterSeveralPauses() {
        let clock = RecordingPauseClock()
        #expect(clock.pause { ms(1_000) })
        #expect(clock.isPaused)
        #expect(clock.adjusted(ms(1_500)) == nil)
        #expect(clock.resume { ms(3_000) })
        #expect(clock.pause { ms(5_000) })
        #expect(clock.resume { ms(5_500) })

        #expect(clock.adjusted(ms(999)) == ms(999))
        #expect(clock.adjusted(ms(1_000)) == nil)
        #expect(clock.adjusted(ms(2_999)) == nil)
        #expect(clock.adjusted(ms(3_000)) == ms(1_000))
        #expect(clock.adjusted(ms(4_000)) == ms(2_000))
        #expect(clock.adjusted(ms(5_200)) == nil)
        #expect(clock.adjusted(ms(6_000)) == ms(3_500))
        #expect(clock.pausedSeconds(until: ms(6_000)) == 2.5)
    }

    @Test
    func keepsEveryIntervalForLateDelivery() {
        let clock = RecordingPauseClock()
        for start in stride(from: UInt64(1_000), through: 5_000, by: 1_000) {
            clock.pause { ms(start) }
            clock.resume { ms(start + 500) }
        }
        // Delivered last, captured first.
        #expect(clock.adjusted(ms(900)) == ms(900))
        #expect(clock.adjusted(ms(1_200)) == nil)
        #expect(clock.adjusted(ms(1_700)) == ms(1_200))
        #expect(clock.adjusted(ms(5_700)) == ms(3_200))
    }

    @Test
    func repeatedPauseAndResumeChangeNothing() {
        let clock = RecordingPauseClock()
        #expect(clock.resume { ms(500) } == false)
        #expect(clock.pause { ms(1_000) })
        #expect(clock.pause { ms(2_000) } == false)
        #expect(clock.resume { ms(3_000) })
        #expect(clock.resume { ms(4_000) } == false)
        #expect(clock.adjusted(ms(5_000)) == ms(3_000))
    }

    @Test
    func closingIsTerminal() {
        let clock = RecordingPauseClock()
        clock.close { ms(2_000) }
        clock.close { ms(9_000) }
        #expect(clock.adjusted(ms(1_999)) == ms(1_999))
        #expect(clock.adjusted(ms(2_000)) == nil)
        #expect(clock.pause { ms(3_000) } == false)
        #expect(clock.resume { ms(4_000) } == false)
        #expect(clock.adjusted(ms(60_000)) == nil)
    }

    @Test
    func closingWhilePausedNeverAdmitsThePauseOrWhatFollows() {
        let clock = RecordingPauseClock()
        clock.pause { ms(1_000) }
        clock.close { ms(3_000) }
        #expect(clock.adjusted(ms(999)) == ms(999))
        for time: UInt64 in [1_000, 2_000, 3_000, 3_001, 90_000] {
            #expect(clock.adjusted(ms(time)) == nil)
        }
        #expect(clock.resume { ms(4_000) } == false)
        // The pause ends at the close, however late the question is asked.
        #expect(clock.pausedSeconds(until: ms(3_000)) == 2)
        #expect(clock.pausedSeconds(until: ms(90_000)) == 2)
    }

    @Test
    func cutsFramesExactlyAtBothBoundaries() {
        let clock = RecordingPauseClock()
        clock.pause { ms(1_010) }
        clock.resume { ms(1_060) }
        // 100 ms from 1 000: 10 ms kept, 50 ms paused, 40 ms kept.
        #expect(frames(clock, start: 1_000) == [0..<480, 2_880..<4_800])
        #expect(frames(clock, start: 1_020, count: 480) == [])
        let after = clock.timeline.keptRanges(startNanos: 1_040_000_000, frameCount: 4_800, sampleRate: 48_000)
        #expect(after.map(\.frames) == [960..<4_800])
        #expect(after.map(\.removedNanos) == [50_000_000])
    }

    @Test
    func aFrameOnTheBoundaryIsPausedAndOneBeforeItIsKept() {
        let clock = RecordingPauseClock()
        // Half a frame after frame 480, so frame 480 was captured before the pause.
        clock.pause { HostNanoseconds(nanoseconds: 1_010_010_416) }
        #expect(frames(clock, start: 1_000) == [0..<481])
        clock.resume { HostNanoseconds(nanoseconds: 1_020_010_416) }
        #expect(frames(clock, start: 1_000) == [0..<481, 961..<4_800])
    }

    @Test
    func closeCutsTheBufferItFallsIn() {
        let clock = RecordingPauseClock()
        clock.close { ms(1_050) }
        #expect(frames(clock, start: 1_000) == [0..<2_400])
        #expect(frames(clock, start: 1_050) == [])
    }

    @Test
    func resumeTimeOfAPausedTimeIsWhereThatPauseEnds() {
        let clock = RecordingPauseClock()
        clock.pause { ms(1_000) }
        #expect(clock.timeline.adjustedResumeTime(forPaused: ms(1_500)) == ms(1_000))
        clock.resume { ms(3_000) }
        clock.pause { ms(5_000) }
        clock.resume { ms(5_500) }

        #expect(clock.timeline.adjustedResumeTime(forPaused: ms(999)) == nil)
        #expect(clock.timeline.adjustedResumeTime(forPaused: ms(1_000)) == ms(1_000))
        #expect(clock.timeline.adjustedResumeTime(forPaused: ms(2_999)) == ms(1_000))
        #expect(clock.timeline.adjustedResumeTime(forPaused: ms(3_000)) == nil)
        #expect(clock.timeline.adjustedResumeTime(forPaused: ms(5_200)) == ms(3_000))
        clock.close { ms(6_000) }
        #expect(clock.timeline.adjustedResumeTime(forPaused: ms(6_000)) == nil)
    }

    @Test
    func closeInAdjustedTime() {
        let clock = RecordingPauseClock()
        #expect(clock.timeline.adjustedCloseTime == nil)
        clock.pause { ms(1_000) }
        clock.resume { ms(3_000) }
        clock.close { ms(4_000) }
        #expect(clock.timeline.adjustedCloseTime == ms(2_000))

        let pausedAtClose = RecordingPauseClock()
        pausedAtClose.pause { ms(1_000) }
        pausedAtClose.resume { ms(3_000) }
        pausedAtClose.pause { ms(5_000) }
        pausedAtClose.close { ms(9_000) }
        #expect(pausedAtClose.timeline.adjustedCloseTime == ms(3_000))
    }
}
