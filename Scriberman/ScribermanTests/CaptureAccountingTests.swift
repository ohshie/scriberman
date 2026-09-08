import AVFoundation
import Foundation
import Testing
@testable import Scriberman

/// Covers the invariant that a source's timing sidecar and its audio file describe the same frames.
///
/// The mixdown compares the sidecar's frame total against the decoded sample count exactly, and
/// declines presentation-timestamp alignment for the whole recording when they differ. A mismatch of
/// one buffer therefore costs an entire recording its alignment, so the equality has to hold by
/// construction rather than by luck.
struct CaptureAccountingTests {
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private func makeDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBuffer(frames: Int = 960) throws -> AVAudioPCMBuffer {
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        )
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)[0]
        for index in 0..<frames {
            data[index] = sinf(Float(index) * 0.05) * 0.5
        }
        return buffer
    }

    private func waitForFrames(_ streamer: AudioFileStreamer, toReach target: Int64) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, streamer.framesWritten < target {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForFailures(_ streamer: AudioFileStreamer, toReach target: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, streamer.writeFailureCount < target {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Decoded frame count of a mono float WAV.
    private func decodedFrameCount(of url: URL) throws -> Int {
        Int(try AVAudioFile(forReading: url).length)
    }

    // MARK: - Invariant

    @Test
    func testSuccessfulWriteContributesExactlyOneSegment() async throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mic.wav")
        let streamer = AudioFileStreamer(label: "mic")
        try streamer.prepare(url: url, format: format)

        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 1_000_000)
        await waitForFrames(streamer, toReach: 960)
        streamer.close()

        let sidecar = try #require(AudioFileStreamer.loadTimingSidecar(for: url))
        #expect(sidecar.segments.count == 1)
        #expect(sidecar.totalFrames == 960)
        #expect(try decodedFrameCount(of: url) == 960)
    }

    @Test
    func testWriteAgainstAClosedFileContributesNoSegmentAndCountsAFailure() async throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mic.wav")
        let streamer = AudioFileStreamer(label: "mic")
        try streamer.prepare(url: url, format: format)

        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 1_000_000)
        await waitForFrames(streamer, toReach: 960)
        streamer.close()

        // Arrives after the file closed — the case that used to add a segment with no samples.
        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 21_000_000)
        await waitForFailures(streamer, toReach: 1)

        #expect(streamer.writeFailureCount >= 1)
        let sidecar = try #require(AudioFileStreamer.loadTimingSidecar(for: url))
        #expect(sidecar.totalFrames == 960)
        #expect(try decodedFrameCount(of: url) == 960)
    }

    @Test
    func testSidecarMatchesTheFileAcrossManyWrites() async throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mic.wav")
        let streamer = AudioFileStreamer(label: "mic")
        try streamer.prepare(url: url, format: format)

        for index in 0..<50 {
            streamer.write(buffer: try makeBuffer(), hostTimeNanos: UInt64(index) * 20_000_000 + 1_000)
        }
        await waitForFrames(streamer, toReach: 48_000)
        streamer.close()

        let sidecar = try #require(AudioFileStreamer.loadTimingSidecar(for: url))
        #expect(sidecar.segments.count == 50)
        #expect(sidecar.totalFrames == 48_000)
        #expect(try decodedFrameCount(of: url) == sidecar.totalFrames)
    }

    @Test
    func testSegmentOrderMatchesWriteOrder() async throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mic.wav")
        let streamer = AudioFileStreamer(label: "mic")
        try streamer.prepare(url: url, format: format)

        let times: [UInt64] = (0..<20).map { UInt64($0) * 20_000_000 + 5_000 }
        for time in times {
            streamer.write(buffer: try makeBuffer(), hostTimeNanos: time)
        }
        await waitForFrames(streamer, toReach: 20 * 960)
        streamer.close()

        let sidecar = try #require(AudioFileStreamer.loadTimingSidecar(for: url))
        #expect(sidecar.segments.map(\.startHostTimeNanos) == times)
    }

    // MARK: - Unplaceable buffers

    @Test
    func testBufferWithoutAPresentationTimeIsNeitherWrittenNorSegmented() async throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mic.wav")
        let streamer = AudioFileStreamer(label: "mic")
        try streamer.prepare(url: url, format: format)

        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 1_000_000)
        await waitForFrames(streamer, toReach: 960)
        // No presentation time: cannot be positioned, so it must not reach the file either.
        streamer.write(buffer: try makeBuffer(), hostTimeNanos: nil)
        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 41_000_000)
        await waitForFrames(streamer, toReach: 1_920)
        streamer.close()

        #expect(streamer.unplaceableBufferCount == 1)
        let sidecar = try #require(AudioFileStreamer.loadTimingSidecar(for: url))
        #expect(sidecar.segments.count == 2)
        #expect(sidecar.totalFrames == 1_920)
        #expect(try decodedFrameCount(of: url) == 1_920)
    }

    @Test
    func testDroppedBufferBecomesSilenceOfItsRealDuration() async throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mic.wav")
        let streamer = AudioFileStreamer(label: "mic")
        try streamer.prepare(url: url, format: format)

        // 20 ms buffers. The middle one has no presentation time and is dropped; the third still
        // carries its true time, so the hole is described.
        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 0)
        await waitForFrames(streamer, toReach: 960)
        streamer.write(buffer: try makeBuffer(), hostTimeNanos: nil)
        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 40_000_000)
        await waitForFrames(streamer, toReach: 1_920)
        streamer.close()

        let sidecar = try #require(AudioFileStreamer.loadTimingSidecar(for: url))
        let timeline = SynchronizedAudioTimeline.reconstruct(
            samples: [Float](repeating: 0.1, count: sidecar.totalFrames),
            segments: sidecar.segments,
            referenceHostTimeNanos: 0,
            sampleRate: 48_000
        )
        // One 20 ms hole, padded to exactly 960 frames, and the audio after it stays at its true
        // position rather than being pulled 20 ms earlier.
        #expect(timeline.gapCount == 1)
        #expect(timeline.insertedSilenceFrames == 960)
        #expect(timeline.frames.count == 2_880)
    }

    @Test
    func testActivityIsRecordedEvenForDroppedBuffers() async throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mic.wav")
        let streamer = AudioFileStreamer(label: "mic")
        try streamer.prepare(url: url, format: format)

        // Idle detection must see the microphone is alive whatever the disk does, and whatever
        // happens to buffers that cannot be placed. `CaptureActivityTracker` needs a sustained run
        // (1s above the level floor, with no quiet gap longer than 0.5s) before it reports
        // activity, so feed one — entirely from buffers that are dropped for having no
        // presentation time.
        //
        // Driven until the tracker reports rather than for a fixed wall-clock span: under parallel
        // test load a sleep can overshoot the 0.5s gap tolerance, which restarts the run, so a
        // fixed loop is flaky by construction.
        let buffer = try makeBuffer()
        let deadline = Date().addingTimeInterval(20)
        while streamer.lastActivityAt == nil, Date() < deadline {
            streamer.write(buffer: buffer, hostTimeNanos: nil)
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(streamer.lastActivityAt != nil)
        #expect(streamer.unplaceableBufferCount > 0)
        // Nothing was placeable, so nothing reached the file.
        #expect(streamer.framesWritten == 0)
    }

    // MARK: - Consequence for the mixdown

    @Test
    func testSidecarStillMatchesAfterAWriteFailureMidStream() async throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mic.wav")
        let streamer = AudioFileStreamer(label: "mic")
        try streamer.prepare(url: url, format: format)

        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 0)
        await waitForFrames(streamer, toReach: 960)
        streamer.close()
        // Fails: file is closed.
        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 20_000_000)
        await waitForFailures(streamer, toReach: 1)

        // The equality the mixdown tests must still hold, which is what keeps the recording on the
        // presentation-timestamp path instead of silently downgrading it.
        let sidecar = try #require(AudioFileStreamer.loadTimingSidecar(for: url))
        #expect(sidecar.totalFrames == (try decodedFrameCount(of: url)))
    }
}
