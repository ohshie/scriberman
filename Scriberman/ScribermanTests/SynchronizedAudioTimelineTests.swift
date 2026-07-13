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

    @Test("Early buffer (source faster than wall clock) appends without overwriting")
    func earlyBufferIsAppendedNotOverwritten() {
        var timeline = SynchronizedAudioTimeline(sampleRate: sampleRate)
        timeline.append(samples: [1, 1, 1, 1], at: 0)
        // Presentation time implies frame 2, but 4 frames are already written.
        let pts = 2.0 / sampleRate
        timeline.append(samples: [2, 2], at: pts)
        #expect(timeline.frames.count == 6) // no overwrite, appended contiguously
        #expect(timeline.overlapFrames == 2)
        #expect(timeline.insertedSilenceFrames == 0)
    }
}
