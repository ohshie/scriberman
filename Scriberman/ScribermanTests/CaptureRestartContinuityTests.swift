import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import SwiftData
import Testing
@testable import Scriberman

/// Covers the guarantee that makes a mid-session restart safe: audio captured before the
/// interruption survives it.
///
/// `restartAudioCapture()` — the start-path retry — overwrites the audio files, and its own
/// documentation says that is safe "for exactly one reason: this runs only when zero frames were
/// written, so there is nothing to lose." Mid-session recovery is the caller that breaks that
/// assumption, so it replaces the stream and its handlers while carrying the writers over.
struct CaptureRestartContinuityTests {
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
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
        for frame in 0..<frames {
            data[frame] = sinf(Float(frame) * 0.05) * 0.5
        }
        return buffer
    }

    /// Writes are dispatched to the streamer's own queue, so the counter lands asynchronously.
    private func waitForFrames(
        _ streamer: AudioFileStreamer,
        toReachAtLeast target: Int64,
        timeout: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, streamer.framesWritten < target {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private final class StubCaptureStream: UnifiedCaptureStreaming, @unchecked Sendable {
        private(set) var stopCallCount = 0
        func addStreamOutput(
            _: SCStreamOutput,
            type _: SCStreamOutputType,
            sampleHandlerQueue _: DispatchQueue?
        ) throws {}
        func startCapture() async throws {}
        func stopCapture() async throws { stopCallCount += 1 }
        func updateConfiguration(_: SCStreamConfiguration) async throws {}
    }

    // MARK: - AudioFileStreamer hardening

    @Test
    func testWritingWithNoOpenFileIsCountedAsAFailure() async throws {
        // Previously an optional-chained no-op: it neither threw nor counted, while timing segments
        // kept accumulating — so the sidecar described audio the file never received.
        let root = makeTemporaryDirectory()
        let streamer = AudioFileStreamer(label: "mic")
        try streamer.prepare(url: root.appendingPathComponent("mic.wav"), format: format)
        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 1_000)
        await waitForFrames(streamer, toReachAtLeast: 960)
        streamer.close()

        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 2_000)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, streamer.writeFailureCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(streamer.writeFailureCount >= 1)
    }

    // MARK: - Handler replacement continuity

    @Test
    func testReplacementHandlerContinuesTheSameFileAndSegments() async throws {
        let root = makeTemporaryDirectory()
        let micURL = root.appendingPathComponent("mic.wav")
        let streamer = AudioFileStreamer(label: "mic")

        // The capture before the interruption.
        let original = MicStreamOutputHandler(streamer: streamer)
        original.configureOutput(url: micURL)
        try streamer.prepare(url: micURL, format: format)
        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 1_000_000)
        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 21_000_000)
        await waitForFrames(streamer, toReachAtLeast: 1_920)
        let framesBeforeRestart = streamer.framesWritten
        #expect(framesBeforeRestart == 1_920)

        // The capture after it: a new handler over the same writer.
        let replacement = MicStreamOutputHandler(streamer: streamer)
        replacement.adoptPreparedOutput(url: micURL)
        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 5_000_000_000)
        await waitForFrames(streamer, toReachAtLeast: 2_880)

        #expect(streamer.framesWritten == 2_880)
        #expect(streamer.writeFailureCount == 0)
        _ = original
    }

    @Test
    func testAdoptingAPreparedOutputWritesOneSidecarCoveringBothSpans() async throws {
        let root = makeTemporaryDirectory()
        let micURL = root.appendingPathComponent("mic.wav")
        let streamer = AudioFileStreamer(label: "mic")
        try streamer.prepare(url: micURL, format: format)

        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 1_000_000)
        await waitForFrames(streamer, toReachAtLeast: 960)
        // A four-second outage, then capture resumes.
        streamer.write(buffer: try makeBuffer(), hostTimeNanos: 4_001_000_000)
        await waitForFrames(streamer, toReachAtLeast: 1_920)
        streamer.close()

        let sidecar = try #require(AudioFileStreamer.loadTimingSidecar(for: micURL))
        #expect(sidecar.segments.count == 2)
        #expect(sidecar.totalFrames == 1_920)
        // The gap is carried by the presentation times, which is what lets the mixdown pad the
        // outage with silence of its real duration instead of splicing the two spans together.
        let gapNanos = sidecar.segments[1].startHostTimeNanos - sidecar.segments[0].startHostTimeNanos
        #expect(gapNanos == 4_000_000_000)
    }

    // MARK: - UnifiedCaptureSession streamer reuse

    @Test
    func testSessionBuiltWithReusedStreamersInheritsTheirFrameCounts() async throws {
        let root = makeTemporaryDirectory()
        let micURL = root.appendingPathComponent("mic.wav")
        let appURL = root.appendingPathComponent("app.wav")
        let micStreamer = AudioFileStreamer(label: "mic")
        let appStreamer = AudioFileStreamer(label: "app")
        try micStreamer.prepare(url: micURL, format: format)
        try appStreamer.prepare(url: appURL, format: format)
        micStreamer.write(buffer: try makeBuffer(), hostTimeNanos: 1_000)
        await waitForFrames(micStreamer, toReachAtLeast: 960)

        let replacement = UnifiedCaptureSession(
            micFileURL: micURL,
            appFileURL: appURL,
            processID: 1234,
            micDeviceUID: "device-a",
            notificationCenter: NotificationCenter(),
            reusingStreamers: (mic: micStreamer, app: appStreamer)
        )

        // Constructing the replacement must not have reset or truncated anything.
        #expect(replacement.micFramesWritten == 960)
        #expect(replacement.micWriteFailureCount == 0)
    }

    @Test
    func testSessionBuiltWithoutReuseStartsFromZero() async throws {
        let root = makeTemporaryDirectory()
        let session = UnifiedCaptureSession(
            micFileURL: root.appendingPathComponent("mic.wav"),
            appFileURL: root.appendingPathComponent("app.wav"),
            processID: 1234,
            micDeviceUID: "device-a",
            notificationCenter: NotificationCenter()
        )
        #expect(session.micFramesWritten == 0)
        #expect(session.appFramesWritten == 0)
    }

    @Test
    func testStopPreservingOutputStopsTheStreamButLeavesTheWriterOpen() async throws {
        let root = makeTemporaryDirectory()
        let micURL = root.appendingPathComponent("mic.wav")
        let appURL = root.appendingPathComponent("app.wav")
        let micStreamer = AudioFileStreamer(label: "mic")
        let appStreamer = AudioFileStreamer(label: "app")
        try micStreamer.prepare(url: micURL, format: format)
        try appStreamer.prepare(url: appURL, format: format)
        micStreamer.write(buffer: try makeBuffer(), hostTimeNanos: 1_000)
        await waitForFrames(micStreamer, toReachAtLeast: 960)

        let session = UnifiedCaptureSession(
            micFileURL: micURL,
            appFileURL: appURL,
            processID: 1234,
            micDeviceUID: "device-a",
            notificationCenter: NotificationCenter(),
            reusingStreamers: (mic: micStreamer, app: appStreamer)
        )
        let stream = StubCaptureStream()
        session.attachStreamForTesting(stream)

        await session.stopStreamPreservingOutput()

        #expect(stream.stopCallCount == 1)
        // No sidecar yet: writing one would finalize a recording that is still running.
        let sidecarURL = AudioFileStreamer.timingSidecarURL(for: micURL)
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path))
        // And the writer is still open, so the capture that replaces this one keeps appending.
        micStreamer.write(buffer: try makeBuffer(), hostTimeNanos: 5_000_000_000)
        await waitForFrames(micStreamer, toReachAtLeast: 1_920)
        #expect(micStreamer.framesWritten == 1_920)
        #expect(micStreamer.writeFailureCount == 0)
    }

    @Test
    func testFullStopClosesTheWritersAndWritesTheSidecar() async throws {
        let root = makeTemporaryDirectory()
        let micURL = root.appendingPathComponent("mic.wav")
        let appURL = root.appendingPathComponent("app.wav")
        let micStreamer = AudioFileStreamer(label: "mic")
        let appStreamer = AudioFileStreamer(label: "app")
        try micStreamer.prepare(url: micURL, format: format)
        try appStreamer.prepare(url: appURL, format: format)
        micStreamer.write(buffer: try makeBuffer(), hostTimeNanos: 1_000)
        await waitForFrames(micStreamer, toReachAtLeast: 960)

        let session = UnifiedCaptureSession(
            micFileURL: micURL,
            appFileURL: appURL,
            processID: 1234,
            micDeviceUID: "device-a",
            notificationCenter: NotificationCenter(),
            reusingStreamers: (mic: micStreamer, app: appStreamer)
        )
        session.attachStreamForTesting(StubCaptureStream())

        await session.stop()

        let sidecarURL = AudioFileStreamer.timingSidecarURL(for: micURL)
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    // MARK: - The start-path restart refuses to destroy captured audio

    @MainActor
    private func makeService() throws -> RecordingService {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: AppAudioSettings()
        )
    }

    @Test @MainActor
    func testStartPathRestartIsRefusedOnceFramesHaveBeenWritten() async throws {
        let root = makeTemporaryDirectory()
        let micURL = root.appendingPathComponent("mic.wav")
        let appURL = root.appendingPathComponent("app.wav")
        let micStreamer = AudioFileStreamer(label: "mic")
        let appStreamer = AudioFileStreamer(label: "app")
        try micStreamer.prepare(url: micURL, format: format)
        try appStreamer.prepare(url: appURL, format: format)
        micStreamer.write(buffer: try makeBuffer(), hostTimeNanos: 1_000)
        await waitForFrames(micStreamer, toReachAtLeast: 960)

        let session = UnifiedCaptureSession(
            micFileURL: micURL,
            appFileURL: appURL,
            processID: 1234,
            micDeviceUID: "device-a",
            notificationCenter: NotificationCenter(),
            reusingStreamers: (mic: micStreamer, app: appStreamer)
        )

        let service = try makeService()
        await service.setRecordingStateForTesting(
            isRecording: true,
            activeAppFileURL: appURL,
            activeAppProcessID: 1234
        )
        await service.setMicRecoveryStateForTesting(desiredMicDeviceUID: nil, micFileURL: micURL)
        await service.setUnifiedCaptureSessionForTesting(session)

        let didRestart = await service.restartAudioCapture()

        #expect(!didRestart)
        // It must bail before teardown: the captured audio and its writer are untouched.
        let counts = await service.captureFrameCounts()
        #expect(counts.mic == 960)
        #expect(micStreamer.writeFailureCount == 0)
    }
}
