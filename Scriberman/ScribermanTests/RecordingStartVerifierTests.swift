import Foundation
import Testing
@testable import Scriberman

struct RecordingStartVerifierTests {
    @Test
    func testMicWritingIsHealthy() {
        #expect(RecordingStartVerifier.verdict(micFrames: 512, appFrames: 0) == .healthy)
        #expect(RecordingStartVerifier.verdict(micFrames: 512, appFrames: nil) == .healthy)
        #expect(RecordingStartVerifier.verdict(micFrames: 1, appFrames: 1) == .healthy)
    }

    /// The case the whole design turns on: frames are arriving, nobody is talking. A level- or
    /// activity-based check would call this a failure and tear the recording down.
    @Test
    func testSilentRoomWithFramesFlowingIsHealthy() {
        #expect(RecordingStartVerifier.verdict(micFrames: 48_000, appFrames: 48_000) == .healthy)
    }

    @Test
    func testNothingWritingIsDead() {
        #expect(RecordingStartVerifier.verdict(micFrames: 0, appFrames: 0) == .dead)
        #expect(RecordingStartVerifier.verdict(micFrames: 0, appFrames: nil) == .dead)
    }

    /// A quiet app in the first seconds is normal — the user starts recording, then joins the
    /// call. This must never be a start failure.
    @Test
    func testZeroAppFramesAloneIsNeverAStartFailure() {
        #expect(RecordingStartVerifier.verdict(micFrames: 512, appFrames: 0) == .healthy)
    }

    /// Mic dead but app audio arriving still captures the other side of the call.
    @Test
    func testAppWritingWithoutMicIsHealthy() {
        #expect(RecordingStartVerifier.verdict(micFrames: 0, appFrames: 512) == .healthy)
    }

    // MARK: - Stop-time app-audio degrade

    @Test
    func testAppSourceThatWroteNothingIsFinalizedWithoutAppAudio() {
        #expect(RecordingStartVerifier.shouldFinalizeWithoutAppAudio(appFrames: 0))
    }

    /// Frames written — even all-silent ones — mean app audio arrived. This must not degrade.
    @Test
    func testAppSourceThatWroteFramesIsNotDegraded() {
        #expect(!RecordingStartVerifier.shouldFinalizeWithoutAppAudio(appFrames: 1))
        #expect(!RecordingStartVerifier.shouldFinalizeWithoutAppAudio(appFrames: 48_000))
    }

    /// A mic-only recording has no app source, so there is nothing to degrade.
    @Test
    func testRecordingWithoutAppAudioIsNotDegraded() {
        #expect(!RecordingStartVerifier.shouldFinalizeWithoutAppAudio(appFrames: nil))
    }

    /// The recorder fallback does not write through `AudioFileStreamer`, so an absent count is
    /// not evidence of failure.
    @Test
    func testUnavailableMicCountIsUnverifiableNotDead() {
        #expect(RecordingStartVerifier.verdict(micFrames: nil, appFrames: nil) == .unverifiable)
        #expect(RecordingStartVerifier.verdict(micFrames: nil, appFrames: 0) == .unverifiable)
    }
    // MARK: - Source coverage

    private let duration: TimeInterval = 600   // ten minutes
    private let rate: Double = 48_000

    @Test
    func testFullyCoveredSourceIsNotMarked() {
        let frames = Int64(duration * rate)
        #expect(!RecordingStartVerifier.isSourcePartiallyCovered(frames: frames, duration: duration))
    }

    @Test
    func testSourceThatStoppedPartwayIsMarked() {
        // Covered four of ten minutes.
        let frames = Int64(240 * rate)
        #expect(RecordingStartVerifier.isSourcePartiallyCovered(frames: frames, duration: duration))
    }

    @Test
    func testUncapturedSourceIsNotMarked() {
        // nil means the source was not captured at all, or is unmeasurable under the recorder
        // fallback. Neither is evidence of partial capture.
        #expect(!RecordingStartVerifier.isSourcePartiallyCovered(frames: nil, duration: duration))
    }

    @Test
    func testZeroCoverageIsMarked() {
        #expect(RecordingStartVerifier.isSourcePartiallyCovered(frames: 0, duration: duration))
    }

    /// A recording legitimately starts before its owner joins a call. A short lead-in must not be
    /// reported as a fault, which is what the uncovered-seconds floor is for.
    @Test
    func testShortLeadInOnAShortRecordingIsNotMarked() {
        // 20 seconds missing from a 60-second recording: 67% covered, under the ratio, but only
        // 20 seconds uncovered.
        let shortDuration: TimeInterval = 60
        let frames = Int64(40 * rate)
        #expect(!RecordingStartVerifier.isSourcePartiallyCovered(frames: frames, duration: shortDuration))
    }

    @Test
    func testLongLeadInOnALongRecordingIsMarked() {
        // The same 67% coverage, but four minutes of a ten-minute recording are missing.
        let frames = Int64(400 * rate)
        #expect(RecordingStartVerifier.isSourcePartiallyCovered(frames: frames, duration: duration))
    }

    @Test
    func testCoverageIsClampedAndHandlesZeroDuration() {
        #expect(RecordingStartVerifier.sourceCoverage(frames: 0, duration: 0) == nil)
        #expect(RecordingStartVerifier.sourceCoverage(frames: nil, duration: duration) == nil)
        // Rounding can produce marginally more frames than the duration spans.
        let overshoot = Int64(duration * rate) + 4_800
        #expect(RecordingStartVerifier.sourceCoverage(frames: overshoot, duration: duration) == 1)
    }

    /// Zero coverage keeps its existing consequence: the recording is finalized microphone-only.
    @Test
    func testZeroFramesStillFinalizesWithoutAppAudio() {
        #expect(RecordingStartVerifier.shouldFinalizeWithoutAppAudio(appFrames: 0))
        #expect(!RecordingStartVerifier.shouldFinalizeWithoutAppAudio(appFrames: 1))
        #expect(!RecordingStartVerifier.shouldFinalizeWithoutAppAudio(appFrames: nil))
    }

}
