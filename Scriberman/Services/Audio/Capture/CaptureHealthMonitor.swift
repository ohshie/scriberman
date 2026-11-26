import Foundation

/// Decides whether an active recording's capture is still alive, and what to do when it is not.
///
/// Pure and time-injected: every decision is a function of `now` plus a snapshot of the frame
/// counts `RecordingService.captureFrameCounts()` already gathers, so the whole state machine is
/// unit-testable without waiting on real clocks or driving a capture session. It owns no timer,
/// touches no capture, and performs no I/O — the caller owns the clock and performs the effects.
/// This mirrors `RecordingStartVerifier` and `IdlePromptStateMachine`.
///
/// It exists because capture health was read exactly once per recording, one second after start.
/// A stream that died afterwards left `isRecordingValue == true` and the recording looked healthy
/// for the rest of its duration.
struct CaptureHealthMonitor: Equatable {
    /// What the caller should do as a result of this evaluation.
    enum Effect: Equatable {
        /// Capture is healthy, or the situation is not one this monitor acts on.
        case none
        /// Capture is dead. Restart it in place, preserving the session and the audio already
        /// captured.
        case restart
        /// Restarting has not helped within the budget. Stop the recording, finalize what was
        /// captured, and report the failure.
        case fail
    }

    /// The per-tick observation. Mirrors the shape of `captureFrameCounts()`, plus a monotonic
    /// count of stream failures reported since the recording began.
    ///
    /// A `nil` frame count means the source is not being measured — the microphone under the
    /// `AVAudioRecorder` fallback, which does not write through `AudioFileStreamer`, or app audio
    /// when no app is being captured. An unmeasured source is never judged stalled: an unavailable
    /// count is not evidence of failure.
    struct Snapshot: Equatable {
        var micFrames: Int64?
        var appFrames: Int64?
        /// Monotonically increasing. An increase since the last tick means a capture stream
        /// reported that it stopped, which is direct evidence of death rather than an inference.
        var streamFailureCount: Int
        /// How many of `streamFailureCount` were already dealt with elsewhere, by a resume that
        /// checked and restarted capture. Those are not acted on again.
        var handledStreamFailureCount: Int

        /// The latest removal of the captured mic or switch to another device, if any.
        var lastMicTransition: MicTransition?
        /// Writes that failed since the recording began, for the failure log. Not judged here.
        var micWriteFailures = 0
        var appWriteFailures = 0

        init(micFrames: Int64?, appFrames: Int64?, streamFailureCount: Int = 0, handledStreamFailureCount: Int = 0) {
            self.micFrames = micFrames
            self.appFrames = appFrames
            self.streamFailureCount = streamFailureCount
            self.handledStreamFailureCount = handledStreamFailureCount
        }
    }

    /// A removal of the captured microphone, or a switch of capture to another device. `number`
    /// increases with each transition, so one transition earns one grace period.
    struct MicTransition: Equatable, Sendable {
        let number: Int
        let at: Date
    }

    /// What happened to the grace period on the most recent evaluation, for the caller to log.
    enum GraceEvent: Equatable {
        case started
        /// Mic buffers arrived within it.
        case recovered
        /// It ran out with no mic buffers; the stall is handled as dead capture.
        case expired
    }

    /// A mic stall that began this close to a transition gets a grace period instead of a restart.
    static let graceWindowAroundTransition: TimeInterval = 2
    /// How long the new device has to deliver mic buffers.
    static let gracePeriod: TimeInterval = 5

    struct Configuration: Equatable {
        /// How long a measured source may go without its frame count advancing before it counts as
        /// stalled. Buffers are uniformly 960 frames (20 ms at 48 kHz), so the default is roughly
        /// 150 consecutive missed buffers — unambiguous, and short enough to lose little audio.
        var stallThreshold: TimeInterval
        /// Restarts issued without capture recovering in between, before giving up.
        var consecutiveRestartLimit: Int
        /// Total restarts allowed for one recording, so a source that dies every few seconds for
        /// hours cannot thrash indefinitely.
        var totalRestartLimit: Int

        static let `default` = Configuration(
            stallThreshold: 3,
            consecutiveRestartLimit: 3,
            totalRestartLimit: 10
        )
    }

    private var configuration: Configuration
    private var micTracker = SourceTracker()
    private var appTracker = SourceTracker()
    private var lastSeenStreamFailureCount = 0
    private var hasSeenFirstTick = false
    /// When the current grace period began; nil outside one.
    private var graceStartedAt: Date?
    /// The newest transition a grace period was already used for.
    private var graceUsedForTransition = 0

    private(set) var lastGraceEvent: GraceEvent?

    private(set) var restartsIssued = 0
    private(set) var consecutiveRestartsWithoutRecovery = 0
    /// Restarts for a mic stall without the mic recovering in between. App frames do not reset it:
    /// with live app audio and a dead mic, the shared counter above never reaches its limit.
    private(set) var consecutiveMicStallRestarts = 0
    /// Whether this recording has been restarted at least once, for the session marker.
    var wasInterrupted: Bool { restartsIssued > 0 }

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Advance the machine one tick.
    ///
    /// - Parameters:
    ///   - now: the caller's clock.
    ///   - snapshot: frame counts and the reported stream-failure count.
    ///   - isRecording: gates the whole monitor; a stopped recording resets it.
    mutating func update(now: Date, snapshot: Snapshot, isRecording: Bool) -> Effect {
        lastGraceEvent = nil
        guard isRecording else {
            reset()
            return .none
        }

        // First observation establishes the baseline. Nothing can be stalled yet, but a failure
        // reported before it is still a failure.
        guard hasSeenFirstTick else {
            hasSeenFirstTick = true
            micTracker.observe(count: snapshot.micFrames, at: now)
            appTracker.observe(count: snapshot.appFrames, at: now)
            let streamFailed = snapshot.streamFailureCount > max(lastSeenStreamFailureCount, snapshot.handledStreamFailureCount)
            lastSeenStreamFailureCount = snapshot.streamFailureCount
            return streamFailed ? restartOrFail(now: now) : .none
        }

        let micAdvanced = micTracker.observe(count: snapshot.micFrames, at: now)
        let appAdvanced = appTracker.observe(count: snapshot.appFrames, at: now)

        // Any source producing audio means the last restart, if there was one, took hold.
        if micAdvanced || appAdvanced {
            consecutiveRestartsWithoutRecovery = 0
        }
        if micAdvanced {
            consecutiveMicStallRestarts = 0
        }

        let streamFailed = snapshot.streamFailureCount > max(lastSeenStreamFailureCount, snapshot.handledStreamFailureCount)
        lastSeenStreamFailureCount = snapshot.streamFailureCount

        // A reported stream error is direct evidence and does not wait out the stall threshold.
        // Otherwise the trigger is the microphone: it is the source whose loss makes a recording
        // worthless, and under unified capture a dead microphone means the shared stream is gone.
        //
        // App audio stalling on its own deliberately does NOT restart. Under unified capture,
        // restarting to chase app audio would tear down a healthy microphone — and the usual cause
        // is that the captured application quit or never activated an audio session, which is
        // already handled at stop by `RecordingStartVerifier.shouldFinalizeWithoutAppAudio`.
        if streamFailed {
            return restartOrFail(now: now)
        }
        if graceStartedAt != nil, micAdvanced {
            graceStartedAt = nil
            lastGraceEvent = .recovered
        }
        if let graceStartedAt {
            guard now.timeIntervalSince(graceStartedAt) > Self.gracePeriod else {
                return .none
            }
            lastGraceEvent = .expired
            return restartOrFail(now: now, forMicStall: true)
        }
        guard micTracker.isStalled(now: now, threshold: configuration.stallThreshold) else {
            return .none
        }
        if startsGracePeriod(now: now, transition: snapshot.lastMicTransition) {
            return .none
        }
        return restartOrFail(now: now, forMicStall: true)
    }

    /// Restarts the stall clocks without touching the restart budget. For a resume: no frames are
    /// written during a pause, so the time it lasted is not a stall.
    mutating func restartStallClocks(at now: Date) {
        micTracker.deferJudgement(to: now)
        appTracker.deferJudgement(to: now)
        // A grace period running when the pause began gets its full length again.
        if graceStartedAt != nil {
            graceStartedAt = now
        }
    }

    /// Starts a grace period when the mic stall began within the window around a transition that
    /// has not had one yet.
    private mutating func startsGracePeriod(now: Date, transition: MicTransition?) -> Bool {
        guard let transition, transition.number > graceUsedForTransition,
              let stallBegan = micTracker.lastAdvancedAt,
              abs(transition.at.timeIntervalSince(stallBegan)) <= Self.graceWindowAroundTransition
        else {
            return false
        }
        graceUsedForTransition = transition.number
        graceStartedAt = now
        lastGraceEvent = .started
        return true
    }

    /// Capture is dead: restart within the budget, or give up.
    private mutating func restartOrFail(now: Date, forMicStall: Bool = false) -> Effect {
        guard consecutiveRestartsWithoutRecovery < configuration.consecutiveRestartLimit,
              !forMicStall || consecutiveMicStallRestarts < configuration.consecutiveRestartLimit,
              restartsIssued < configuration.totalRestartLimit
        else {
            return .fail
        }

        graceStartedAt = nil
        restartsIssued += 1
        consecutiveRestartsWithoutRecovery += 1
        if forMicStall {
            consecutiveMicStallRestarts += 1
        }
        // Give the restart a full threshold to prove itself rather than judging it against the
        // clock of the capture it replaced.
        micTracker.deferJudgement(to: now)
        appTracker.deferJudgement(to: now)
        return .restart
    }

    private mutating func reset() {
        micTracker = SourceTracker()
        appTracker = SourceTracker()
        lastSeenStreamFailureCount = 0
        hasSeenFirstTick = false
        restartsIssued = 0
        consecutiveRestartsWithoutRecovery = 0
        consecutiveMicStallRestarts = 0
        graceStartedAt = nil
        graceUsedForTransition = 0
    }

    /// Tracks one source's frame count and when it last advanced.
    private struct SourceTracker: Equatable {
        private var lastCount: Int64?
        private(set) var lastAdvancedAt: Date?

        /// Records an observation. Returns whether the count advanced.
        ///
        /// A `nil` count means the source is not measured; its clock is held at `now` so an
        /// unmeasurable source can never accumulate toward a stall.
        @discardableResult
        mutating func observe(count: Int64?, at now: Date) -> Bool {
            guard let count else {
                lastCount = nil
                lastAdvancedAt = now
                return false
            }
            defer { lastCount = count }
            guard let previous = lastCount else {
                lastAdvancedAt = now
                return false
            }
            guard count > previous else {
                return false
            }
            lastAdvancedAt = now
            return true
        }

        func isStalled(now: Date, threshold: TimeInterval) -> Bool {
            // An unmeasured source is never stalled: no count is not the same as no audio.
            guard lastCount != nil, let lastAdvancedAt else {
                return false
            }
            return now.timeIntervalSince(lastAdvancedAt) > threshold
        }

        /// Restarts the stall clock without treating it as an advance.
        mutating func deferJudgement(to now: Date) {
            lastAdvancedAt = now
        }
    }
}
