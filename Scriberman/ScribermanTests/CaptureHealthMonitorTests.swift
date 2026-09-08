import Foundation
import Testing
@testable import Scriberman

/// Covers the decision logic that decides an active recording's capture has died.
///
/// Every case is driven by an injected clock, so nothing here waits on real seconds.
struct CaptureHealthMonitorTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func config(
        stallThreshold: TimeInterval = 3,
        consecutiveRestartLimit: Int = 3,
        totalRestartLimit: Int = 10
    ) -> CaptureHealthMonitor.Configuration {
        CaptureHealthMonitor.Configuration(
            stallThreshold: stallThreshold,
            consecutiveRestartLimit: consecutiveRestartLimit,
            totalRestartLimit: totalRestartLimit
        )
    }

    private func snapshot(
        mic: Int64?,
        app: Int64? = nil,
        failures: Int = 0
    ) -> CaptureHealthMonitor.Snapshot {
        CaptureHealthMonitor.Snapshot(micFrames: mic, appFrames: app, streamFailureCount: failures)
    }

    // MARK: - Baseline and healthy capture

    @Test
    func testFirstTickEstablishesBaselineAndDoesNotAct() {
        var monitor = CaptureHealthMonitor(configuration: config())
        let effect = monitor.update(now: start, snapshot: snapshot(mic: 0), isRecording: true)
        #expect(effect == .none)
    }

    @Test
    func testAdvancingFramesStayHealthyIndefinitely() {
        var monitor = CaptureHealthMonitor(configuration: config())
        var frames: Int64 = 0
        _ = monitor.update(now: start, snapshot: snapshot(mic: frames), isRecording: true)

        for tick in 1...200 {
            frames += 960
            let effect = monitor.update(
                now: start.addingTimeInterval(Double(tick)),
                snapshot: snapshot(mic: frames),
                isRecording: true
            )
            #expect(effect == .none)
        }
        #expect(monitor.restartsIssued == 0)
        #expect(!monitor.wasInterrupted)
    }

    @Test
    func testSilenceIsHealthyBecauseFramesStillAdvance() {
        // A silent room still produces buffers at the capture rate. This is the case that rules out
        // levels and activity timestamps as the detection signal.
        var monitor = CaptureHealthMonitor(configuration: config())
        _ = monitor.update(now: start, snapshot: snapshot(mic: 0), isRecording: true)

        let effect = monitor.update(
            now: start.addingTimeInterval(60),
            snapshot: snapshot(mic: 2_880_000),
            isRecording: true
        )
        #expect(effect == .none)
    }

    // MARK: - Stall detection

    @Test
    func testStalledMicIsNotJudgedBeforeTheThreshold() {
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3))
        _ = monitor.update(now: start, snapshot: snapshot(mic: 960), isRecording: true)

        let effect = monitor.update(
            now: start.addingTimeInterval(2.9),
            snapshot: snapshot(mic: 960),
            isRecording: true
        )
        #expect(effect == .none)
    }

    @Test
    func testStalledMicIsDetectedPastTheThreshold() {
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3))
        _ = monitor.update(now: start, snapshot: snapshot(mic: 960), isRecording: true)

        let effect = monitor.update(
            now: start.addingTimeInterval(3.1),
            snapshot: snapshot(mic: 960),
            isRecording: true
        )
        #expect(effect == .restart)
        #expect(monitor.wasInterrupted)
    }

    // MARK: - D4 trigger table

    @Test
    func testStreamErrorRestartsImmediatelyWithoutWaitingOutTheThreshold() {
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3))
        _ = monitor.update(now: start, snapshot: snapshot(mic: 960), isRecording: true)

        // Frames are still advancing; only the reported failure says the stream is gone.
        let effect = monitor.update(
            now: start.addingTimeInterval(0.05),
            snapshot: snapshot(mic: 1_920, failures: 1),
            isRecording: true
        )
        #expect(effect == .restart)
    }

    @Test
    func testBothSourcesStalledRestarts() {
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3))
        _ = monitor.update(now: start, snapshot: snapshot(mic: 960, app: 960), isRecording: true)

        let effect = monitor.update(
            now: start.addingTimeInterval(4),
            snapshot: snapshot(mic: 960, app: 960),
            isRecording: true
        )
        #expect(effect == .restart)
    }

    @Test
    func testAppOnlyStallDoesNotRestart() {
        // Restarting to chase app audio would tear down a healthy microphone, and the usual cause
        // is the captured app quitting — already handled at stop.
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3))
        _ = monitor.update(now: start, snapshot: snapshot(mic: 960, app: 960), isRecording: true)

        let effect = monitor.update(
            now: start.addingTimeInterval(30),
            snapshot: snapshot(mic: 1_440_000, app: 960),
            isRecording: true
        )
        #expect(effect == .none)
        #expect(monitor.restartsIssued == 0)
    }

    @Test
    func testMicOnlyStallRestarts() {
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3))
        _ = monitor.update(now: start, snapshot: snapshot(mic: 960, app: 960), isRecording: true)

        let effect = monitor.update(
            now: start.addingTimeInterval(4),
            snapshot: snapshot(mic: 960, app: 1_440_000),
            isRecording: true
        )
        #expect(effect == .restart)
    }

    // MARK: - Unmeasured sources

    @Test
    func testRecorderFallbackMicIsNeverJudgedStalled() {
        // A nil mic count means the AVAudioRecorder fallback is active, which does not write
        // through AudioFileStreamer. An unavailable count is not evidence of failure.
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3))
        _ = monitor.update(now: start, snapshot: snapshot(mic: nil), isRecording: true)

        let effect = monitor.update(
            now: start.addingTimeInterval(600),
            snapshot: snapshot(mic: nil),
            isRecording: true
        )
        #expect(effect == .none)
    }

    @Test
    func testUncapturedAppAudioIsNeverJudgedStalled() {
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3))
        _ = monitor.update(now: start, snapshot: snapshot(mic: 960, app: nil), isRecording: true)

        let effect = monitor.update(
            now: start.addingTimeInterval(30),
            snapshot: snapshot(mic: 1_440_000, app: nil),
            isRecording: true
        )
        #expect(effect == .none)
    }

    @Test
    func testStreamErrorStillRestartsUnderTheRecorderFallback() {
        var monitor = CaptureHealthMonitor(configuration: config())
        _ = monitor.update(now: start, snapshot: snapshot(mic: nil), isRecording: true)

        let effect = monitor.update(
            now: start.addingTimeInterval(1),
            snapshot: snapshot(mic: nil, failures: 1),
            isRecording: true
        )
        #expect(effect == .restart)
    }

    // MARK: - Restart budget

    @Test
    func testRestartIsGivenAFullThresholdToProveItself() {
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3))
        _ = monitor.update(now: start, snapshot: snapshot(mic: 960), isRecording: true)
        #expect(monitor.update(now: start.addingTimeInterval(4), snapshot: snapshot(mic: 960), isRecording: true) == .restart)

        // Immediately after the restart the source has not produced anything yet, but the clock
        // was reset, so it must not be judged again straight away.
        let effect = monitor.update(
            now: start.addingTimeInterval(5),
            snapshot: snapshot(mic: 960),
            isRecording: true
        )
        #expect(effect == .none)
    }

    @Test
    func testConsecutiveFailedRestartsExhaustTheBudgetAndFail() {
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3, consecutiveRestartLimit: 3))
        _ = monitor.update(now: start, snapshot: snapshot(mic: 960), isRecording: true)

        var elapsed: TimeInterval = 0
        for attempt in 1...3 {
            elapsed += 4
            let effect = monitor.update(
                now: start.addingTimeInterval(elapsed),
                snapshot: snapshot(mic: 960),
                isRecording: true
            )
            #expect(effect == .restart, "attempt \(attempt) should restart")
        }

        elapsed += 4
        let effect = monitor.update(
            now: start.addingTimeInterval(elapsed),
            snapshot: snapshot(mic: 960),
            isRecording: true
        )
        #expect(effect == .fail)
        #expect(monitor.restartsIssued == 3)
    }

    @Test
    func testRecoveryResetsTheConsecutiveCounter() {
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3, consecutiveRestartLimit: 3))
        var frames: Int64 = 960
        _ = monitor.update(now: start, snapshot: snapshot(mic: frames), isRecording: true)

        // Two failed restarts...
        #expect(monitor.update(now: start.addingTimeInterval(4), snapshot: snapshot(mic: frames), isRecording: true) == .restart)
        #expect(monitor.update(now: start.addingTimeInterval(8), snapshot: snapshot(mic: frames), isRecording: true) == .restart)
        #expect(monitor.consecutiveRestartsWithoutRecovery == 2)

        // ...then capture comes back.
        frames += 960
        #expect(monitor.update(now: start.addingTimeInterval(9), snapshot: snapshot(mic: frames), isRecording: true) == .none)
        #expect(monitor.consecutiveRestartsWithoutRecovery == 0)

        // A later death gets the full budget again rather than inheriting the earlier failures.
        #expect(monitor.update(now: start.addingTimeInterval(13), snapshot: snapshot(mic: frames), isRecording: true) == .restart)
        #expect(monitor.restartsIssued == 3)
    }

    @Test
    func testTotalCeilingStopsThrashingEvenWhenEachRestartRecovers() {
        var monitor = CaptureHealthMonitor(
            configuration: config(stallThreshold: 3, consecutiveRestartLimit: 3, totalRestartLimit: 4)
        )
        var frames: Int64 = 960
        var elapsed: TimeInterval = 0
        _ = monitor.update(now: start, snapshot: snapshot(mic: frames), isRecording: true)

        // Each cycle: capture dies, restarts, and recovers — so the consecutive counter never
        // trips. Only the per-recording ceiling can stop this.
        for _ in 1...4 {
            elapsed += 4
            #expect(monitor.update(now: start.addingTimeInterval(elapsed), snapshot: snapshot(mic: frames), isRecording: true) == .restart)
            elapsed += 1
            frames += 960
            #expect(monitor.update(now: start.addingTimeInterval(elapsed), snapshot: snapshot(mic: frames), isRecording: true) == .none)
        }

        elapsed += 4
        let effect = monitor.update(
            now: start.addingTimeInterval(elapsed),
            snapshot: snapshot(mic: frames),
            isRecording: true
        )
        #expect(effect == .fail)
        #expect(monitor.restartsIssued == 4)
    }

    // MARK: - Lifecycle

    @Test
    func testNotRecordingResetsTheMonitor() {
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3))
        _ = monitor.update(now: start, snapshot: snapshot(mic: 960), isRecording: true)
        #expect(monitor.update(now: start.addingTimeInterval(4), snapshot: snapshot(mic: 960), isRecording: true) == .restart)

        #expect(monitor.update(now: start.addingTimeInterval(5), snapshot: snapshot(mic: 960), isRecording: false) == .none)
        #expect(monitor.restartsIssued == 0)
        #expect(!monitor.wasInterrupted)

        // The next recording starts from a clean baseline, not mid-stall.
        #expect(monitor.update(now: start.addingTimeInterval(6), snapshot: snapshot(mic: 0), isRecording: true) == .none)
        #expect(monitor.update(now: start.addingTimeInterval(7), snapshot: snapshot(mic: 0), isRecording: true) == .none)
    }

    @Test
    func testStalledRecordingKeepsFailingRatherThanSilentlyResuming() {
        var monitor = CaptureHealthMonitor(configuration: config(stallThreshold: 3, consecutiveRestartLimit: 1))
        _ = monitor.update(now: start, snapshot: snapshot(mic: 960), isRecording: true)
        #expect(monitor.update(now: start.addingTimeInterval(4), snapshot: snapshot(mic: 960), isRecording: true) == .restart)
        #expect(monitor.update(now: start.addingTimeInterval(8), snapshot: snapshot(mic: 960), isRecording: true) == .fail)
        // Still dead on the next tick: the verdict must not flip back to .none and strand the
        // caller mid-failure.
        #expect(monitor.update(now: start.addingTimeInterval(12), snapshot: snapshot(mic: 960), isRecording: true) == .fail)
    }
}
