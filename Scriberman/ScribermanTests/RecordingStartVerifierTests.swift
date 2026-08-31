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
}
