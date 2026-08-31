import Testing
@testable import Scriberman

struct SynchronizedAudioTimelineTests {
    private let sampleRate = 48_000.0

    @Test("First buffer anchors frame 0 regardless of absolute presentation time")
    func firstBufferAnchorsAtZero() {
        var timeline = SynchronizedAudioTimeline(sampleRate: sampleRate)
        timeline.append(samples: [1, 2, 3], at: 123.456)
        #expect(timeline.frames == [1, 2, 3])
        #expect(timeline.insertedSilenceFrames == 0)
        #expect(timeline.gapCount == 0)
    }

    @Test("Contiguous buffers append with no silence")
    func contiguousBuffersHaveNoGap() {
        var timeline = SynchronizedAudioTimeline(sampleRate: sampleRate)
        // 4 samples = 4/48000 s per buffer.
        let dt = 4.0 / sampleRate
        timeline.append(samples: [1, 1, 1, 1], at: 0)
        timeline.append(samples: [2, 2, 2, 2], at: dt)
        #expect(timeline.frames.count == 8)
        #expect(timeline.insertedSilenceFrames == 0)
        #expect(timeline.gapCount == 0)
    }

    @Test("A gap in presentation time inserts exactly that many silence frames")
    func gapInsertsSilence() {
        var timeline = SynchronizedAudioTimeline(sampleRate: sampleRate)
        timeline.append(samples: [1, 1], at: 0)
        // Next buffer should start at frame 100 (100/48000 s), leaving a 98-frame gap.
        let pts = 100.0 / sampleRate
        timeline.append(samples: [2, 2], at: pts)
        #expect(timeline.frames.count == 102)
        #expect(timeline.insertedSilenceFrames == 98)
        #expect(timeline.gapCount == 1)
        // Silence region is zero, and the late buffer landed at frame 100.
        #expect(timeline.frames[2] == 0)
        #expect(timeline.frames[99] == 0)
        #expect(timeline.frames[100] == 2)
        #expect(timeline.frames[101] == 2)
    }

    @Test("A whole capture outage is padded to keep post-outage audio aligned")
    func outageIsPadded() {
        var timeline = SynchronizedAudioTimeline(sampleRate: sampleRate)
        timeline.append(samples: Array(repeating: 1, count: 48_000), at: 0) // 1 s
        // Resume 3 seconds after start (2 s outage after the first second).
        timeline.append(samples: [9], at: 3.0)
        // Expected total length: 3 s + 1 sample = 144001 frames.
        #expect(timeline.frames.count == 144_001)
        #expect(timeline.insertedSilenceFrames == 96_000) // 2 s of silence
        #expect(timeline.frames[144_000] == 9)
    }

    @Test("gapFrames reports the silence needed before a late buffer")
    func gapFramesHelper() {
        var timeline = SynchronizedAudioTimeline(sampleRate: sampleRate)
        timeline.append(samples: [1, 1], at: 0)
        let pts = 100.0 / sampleRate
        #expect(timeline.gapFrames(before: pts, writtenFrames: 2) == 98)
    }

    @Test("Early buffer overlap is trimmed so the timeline stays wall-clock true")
    func earlyBufferOverlapIsTrimmed() {
        var timeline = SynchronizedAudioTimeline(sampleRate: sampleRate)
        timeline.append(samples: [1, 1, 1, 1], at: 0)
        // Presentation time implies frame 2, but 4 frames are already written: 2-frame overlap.
        let pts = 2.0 / sampleRate
        timeline.append(samples: [2, 2, 9], at: pts)
        #expect(timeline.frames.count == 5) // only the non-overlapping tail is appended
        #expect(timeline.frames[4] == 9)
        #expect(timeline.overlapFrames == 2)
        #expect(timeline.insertedSilenceFrames == 0)
    }

    @Test("Fully-duplicate-in-time buffer is dropped")
    func fullyEarlyBufferIsDropped() {
        var timeline = SynchronizedAudioTimeline(sampleRate: sampleRate)
        timeline.append(samples: [1, 1, 1, 1], at: 0)
        // Buffer of 2 frames whose window [2, 4) is already fully written.
        let pts = 2.0 / sampleRate
        timeline.append(samples: [2, 2], at: pts)
        #expect(timeline.frames.count == 4)
        #expect(timeline.overlapFrames == 2)
    }

    @Test("A time-stretched source (surplus frames per buffer) is corrected to wall clock")
    func stretchedSourceIsCorrected() {
        // Regression for the unified-capture converter bug: every buffer carried 544 frames
        // of audio but only 512 frames of wall-clock time (~6.25% stretch), desyncing the
        // channel by ~3.75 s/minute. The timeline must trim the surplus, keeping total
        // length equal to elapsed real time.
        var timeline = SynchronizedAudioTimeline(sampleRate: sampleRate)
        let realFramesPerBuffer = 512
        let surplusFramesPerBuffer = 544
        let bufferCount = 100
        for index in 0..<bufferCount {
            let pts = Double(index * realFramesPerBuffer) / sampleRate
            timeline.append(samples: [Float](repeating: 1, count: surplusFramesPerBuffer), at: pts)
        }
        // Last buffer's tail may legitimately extend past the final PTS; everything before it
        // must be wall-clock true (index * 512), not stretched (index * 544).
        let expectedMax = (bufferCount - 1) * realFramesPerBuffer + surplusFramesPerBuffer
        #expect(timeline.frames.count == expectedMax)
        #expect(timeline.overlapFrames == (bufferCount - 1) * (surplusFramesPerBuffer - realFramesPerBuffer))
    }

    // MARK: - reconstruct (offline, from file samples + segment log)

    private func segment(_ hostNanos: UInt64, _ frames: Int) -> AudioCaptureSegment {
        AudioCaptureSegment(startHostTimeNanos: hostNanos, frameCount: frames)
    }

    @Test("reconstruct with contiguous segments returns the samples unchanged")
    func reconstructContiguous() {
        let samples: [Float] = [1, 2, 3, 4, 5, 6]
        // Two contiguous 3-frame buffers, 3 frames = 3/48000 s apart.
        let dtNanos = UInt64(3.0 / sampleRate * 1_000_000_000)
        let segments = [segment(1_000, 3), segment(1_000 + dtNanos, 3)]
        let timeline = SynchronizedAudioTimeline.reconstruct(
            samples: samples, segments: segments, referenceHostTimeNanos: 1_000, sampleRate: sampleRate
        )
        #expect(timeline.frames == samples)
        #expect(timeline.insertedSilenceFrames == 0)
    }

    @Test("reconstruct anchored to an earlier shared reference adds leading silence")
    func reconstructWithSharedReferenceOffset() {
        let samples: [Float] = [7, 7, 7]
        // Source's first buffer is 100 frames after the shared reference.
        let startNanos = UInt64(100.0 / sampleRate * 1_000_000_000) // relative to reference 0
        let segments = [segment(startNanos, 3)]
        let timeline = SynchronizedAudioTimeline.reconstruct(
            samples: samples, segments: segments, referenceHostTimeNanos: 0, sampleRate: sampleRate
        )
        #expect(timeline.frames.count == 103)
        #expect(timeline.insertedSilenceFrames == 100)
        #expect(timeline.frames[100] == 7)
    }

    @Test("reconstruct fills a mid-recording outage gap with silence")
    func reconstructWithOutage() {
        let samples: [Float] = [1, 1, 9] // 2 frames, then 1 frame after an outage
        let secondStart = UInt64(3.0 * 1_000_000_000) // 3 s after reference
        let segments = [segment(0, 2), segment(secondStart, 1)]
        let timeline = SynchronizedAudioTimeline.reconstruct(
            samples: samples, segments: segments, referenceHostTimeNanos: 0, sampleRate: sampleRate
        )
        #expect(timeline.frames.count == 144_001)
        #expect(timeline.frames[144_000] == 9)
        #expect(timeline.insertedSilenceFrames == 144_000 - 2)
    }

    @Test("Two sources on one shared reference stay aligned")
    func twoSourcesShareReference() {
        // Mic starts at reference; app starts 50 frames later. Both reconstructed against the
        // shared (earlier) reference should place mic at 0 and app at frame 50.
        let micRef: UInt64 = 5_000
        let appStart = micRef + UInt64(50.0 / sampleRate * 1_000_000_000)
        let mic = SynchronizedAudioTimeline.reconstruct(
            samples: [1, 1, 1], segments: [segment(micRef, 3)],
            referenceHostTimeNanos: micRef, sampleRate: sampleRate
        )
        let app = SynchronizedAudioTimeline.reconstruct(
            samples: [2, 2, 2], segments: [segment(appStart, 3)],
            referenceHostTimeNanos: micRef, sampleRate: sampleRate
        )
        #expect(mic.frames.first == 1)
        #expect(app.insertedSilenceFrames == 50)
        #expect(app.frames[50] == 2)
    }
}
