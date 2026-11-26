import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import SwiftData
import Testing
@testable import Scriberman

final class ScreenCaptureSessionTests {
    @Test
    func testStartThrowsWhenDisplayIsNotAvailable() async throws {
        let session = ScreenCaptureSession(displayProvider: { [] })

        await #expect(throws: RecordingError.self) {
            try await session.start(
                displayID: 42,
                videoURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov"),
                pauseClock: RecordingPauseClock()
            )
        }
    }

    @Test
    func testHandleStreamStopInvokesOnError() {
        let session = ScreenCaptureSession(displayProvider: { [] })
        let error = NSError(domain: "ScreenCaptureSessionTests", code: 7)
        let receivedError = ErrorBox()

        session.onError = { receivedError.value = $0 }
        session.handleStreamStop(error)

        #expect((receivedError.value as NSError?)?.domain == error.domain)
        #expect((receivedError.value as NSError?)?.code == error.code)
    }

    // MARK: - Writer and frames

    @Test
    func testFrameDeliveredDuringStartIsWritten() async throws {
        let stream = FakeScreenStream()
        let session = makeSession(stream: stream)
        let videoURL = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let frame = try makeVideoSampleBuffer(hostTimeNanos: 1_000_000_000, status: .complete)
        stream.onStart = { session.processSampleBufferForTesting(frame) }

        try await session.start(displayID: Self.displayID, videoURL: videoURL, pauseClock: RecordingPauseClock())

        #expect(session.frameCountForTesting == 1)
        #expect(session.videoStartHostTime == HostNanoseconds(nanoseconds: 1_000_000_000))
        await session.stop()
    }

    @Test
    func testFirstWrittenFrameSetsTheAnchorAndLaterFramesDoNot() async throws {
        let session = makeSession(stream: FakeScreenStream())
        let videoURL = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try await session.start(displayID: Self.displayID, videoURL: videoURL, pauseClock: RecordingPauseClock())

        session.processSampleBufferForTesting(try makeVideoSampleBuffer(hostTimeNanos: 1_111_000_000, status: .complete))
        session.processSampleBufferForTesting(try makeVideoSampleBuffer(hostTimeNanos: 2_222_000_000, status: .complete))

        #expect(session.videoStartHostTime == HostNanoseconds(nanoseconds: 1_111_000_000))
        await session.stop()
    }

    @Test
    func testSkippedFrameDoesNotSetTheAnchor() async throws {
        let session = makeSession(stream: FakeScreenStream())
        let videoURL = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try await session.start(displayID: Self.displayID, videoURL: videoURL, pauseClock: RecordingPauseClock())

        session.processSampleBufferForTesting(try makeVideoSampleBuffer(hostTimeNanos: 1_000_000_000, status: .idle))
        #expect(session.frameCountForTesting == 0)
        #expect(session.videoStartHostTime == nil)

        session.processSampleBufferForTesting(try makeVideoSampleBuffer(hostTimeNanos: 1_100_000_000, status: .complete))
        #expect(session.frameCountForTesting == 1)
        #expect(session.videoStartHostTime == HostNanoseconds(nanoseconds: 1_100_000_000))
        await session.stop()
    }

    @Test
    func testInvalidAndUnmarkedFramesAreSkipped() async throws {
        let session = makeSession(stream: FakeScreenStream())
        let videoURL = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try await session.start(displayID: Self.displayID, videoURL: videoURL, pauseClock: RecordingPauseClock())

        let invalidated = try makeVideoSampleBuffer(hostTimeNanos: 1_000_000_000, status: .complete)
        CMSampleBufferInvalidate(invalidated)
        session.processSampleBufferForTesting(invalidated)
        session.processSampleBufferForTesting(try makeVideoSampleBuffer(hostTimeNanos: 1_050_000_000, status: nil))

        #expect(session.frameCountForTesting == 0)
        #expect(session.videoStartHostTime == nil)
        await session.stop()
    }

    @Test
    func testLateCallbackFromAStoppedSessionIsIgnored() async throws {
        let session = makeSession(stream: FakeScreenStream())
        let firstURL = temporaryMovieURL()
        let secondURL = temporaryMovieURL()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        try await session.start(displayID: Self.displayID, videoURL: firstURL, pauseClock: RecordingPauseClock())
        let staleGeneration = session.generationForTesting
        await session.stop()
        try await session.start(displayID: Self.displayID, videoURL: secondURL, pauseClock: RecordingPauseClock())

        session.processSampleBufferForTesting(
            try makeVideoSampleBuffer(hostTimeNanos: 1_000_000_000, status: .complete),
            generation: staleGeneration
        )

        #expect(session.frameCountForTesting == 0)
        #expect(session.videoStartHostTime == nil)
        await session.stop()
    }

    @Test
    func testStopWaitsForAnAppendInProgress() async throws {
        let stream = FakeScreenStream()
        let session = makeSession(stream: stream)
        let videoURL = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try await session.start(displayID: Self.displayID, videoURL: videoURL, pauseClock: RecordingPauseClock())
        session.processSampleBufferForTesting(try makeVideoSampleBuffer(hostTimeNanos: 1_000_000_000, status: .complete))

        let appendGate = AppendGate()
        session.setBeforeAppendForTesting { appendGate.enterAndHold(for: 0.3) }
        session.deliverSampleBufferAsyncForTesting(try makeVideoSampleBuffer(hostTimeNanos: 1_500_000_000, status: .complete))
        await appendGate.waitUntilEntered()

        await session.stop()

        #expect(appendGate.didLeave)
        #expect(stream.stopCount == 1)
        let tracks = try await AVURLAsset(url: videoURL).loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        #expect(try await track.load(.timeRange).duration.seconds >= 0.5)
    }

    @Test
    func testPresentationTimeConvertsToNanoseconds() throws {
        let sample = try makeVideoSampleBuffer(hostTimeNanos: 2_500_000_000)

        #expect(HostNanoseconds(presentationTimeOf: sample) == HostNanoseconds(nanoseconds: 2_500_000_000))
    }

    // MARK: - Pause

    /// Raw host time in nanoseconds for `seconds`.
    private static func raw(_ seconds: Double) -> HostNanoseconds {
        HostNanoseconds(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
    }

    private func pause(_ clock: RecordingPauseClock, at seconds: Double) {
        clock.pause(at: { Self.raw(seconds) })
    }

    private func resume(_ clock: RecordingPauseClock, at seconds: Double) {
        clock.resume(at: { Self.raw(seconds) })
    }

    private func deliver(_ session: ScreenCaptureSession, at seconds: Double, _ status: SCFrameStatus, _ color: FrameColor = .blue) throws {
        session.processSampleBufferForTesting(
            try makeVideoSampleBuffer(hostTimeNanos: Int64(Self.raw(seconds).nanoseconds), status: status, color: color)
        )
    }

    private func startPausable(
        clock: RecordingPauseClock,
        timeout: Duration = .seconds(5)
    ) async throws -> (ScreenCaptureSession, URL) {
        let session = makeSession(stream: FakeScreenStream(), frameDeliveryTimeout: timeout)
        let videoURL = temporaryMovieURL()
        try await session.start(displayID: Self.displayID, videoURL: videoURL, pauseClock: clock)
        return (session, videoURL)
    }

    @Test
    func retimedFramesUseAdjustedTimesAndStrictlyIncrease() async throws {
        let clock = RecordingPauseClock()
        let (session, videoURL) = try await startPausable(clock: clock)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        try deliver(session, at: 1.0, .complete, .blue)
        try deliver(session, at: 1.1, .complete, .green)
        pause(clock, at: 1.15)
        try deliver(session, at: 1.5, .complete, .red)
        resume(clock, at: 2.15)
        try deliver(session, at: 2.2, .complete, .white)
        // Same adjusted time as the frame before it.
        try deliver(session, at: 2.2, .complete, .yellow)
        try deliver(session, at: 2.3, .complete, .green)
        clock.close(at: { Self.raw(2.4) })
        await session.stop()

        let frames = try await readFrames(videoURL)
        #expect(frames.map(\.color) == [.blue, .green, .white, .green])
        expectTimes(frames, [0, 0.1, 0.2, 0.3])
        #expect(session.videoStartHostTime == Self.raw(1.0))
    }

    @Test
    func theNewestPausedFrameIsWrittenAtTheResumeTimeAfterAnIdleFrame() async throws {
        let clock = RecordingPauseClock()
        let (session, videoURL) = try await startPausable(clock: clock)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        try deliver(session, at: 1.0, .complete, .blue)
        pause(clock, at: 1.05)
        try deliver(session, at: 1.5, .complete, .yellow)
        try deliver(session, at: 1.6, .complete, .white)
        resume(clock, at: 3.05)
        try deliver(session, at: 3.0, .idle)
        try deliver(session, at: 3.1, .blank)
        try deliver(session, at: 3.15, .suspended)
        #expect(session.frameCountForTesting == 1)
        try deliver(session, at: 3.2, .idle)
        #expect(session.frameCountForTesting == 2)
        try deliver(session, at: 3.3, .idle)
        #expect(session.frameCountForTesting == 2)
        clock.close(at: { Self.raw(3.5) })
        await session.stop()

        let frames = try await readFrames(videoURL)
        #expect(frames.map(\.color) == [.blue, .white])
        expectTimes(frames, [0, 0.05])
    }

    @Test
    func aNewerCompleteFrameReplacesThePausedFrame() async throws {
        let clock = RecordingPauseClock()
        let (session, videoURL) = try await startPausable(clock: clock)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        try deliver(session, at: 1.0, .complete, .blue)
        pause(clock, at: 1.05)
        try deliver(session, at: 1.5, .complete, .red)
        resume(clock, at: 3.05)
        try deliver(session, at: 3.2, .complete, .green)
        try deliver(session, at: 3.3, .idle)
        clock.close(at: { Self.raw(3.5) })
        await session.stop()

        let frames = try await readFrames(videoURL)
        #expect(frames.map(\.color) == [.blue, .green])
        expectTimes(frames, [0, 0.2])
    }

    @Test(arguments: [true, false])
    func stopDropsThePausedFrame(whilePaused: Bool) async throws {
        let clock = RecordingPauseClock()
        let (session, videoURL) = try await startPausable(clock: clock)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        try deliver(session, at: 1.0, .complete, .blue)
        pause(clock, at: 1.05)
        try deliver(session, at: 1.5, .complete, .red)
        if !whilePaused {
            resume(clock, at: 3.05)
            try deliver(session, at: 3.1, .blank)
        }
        clock.close(at: { Self.raw(3.5) })
        try deliver(session, at: 3.6, .idle)
        await session.stop()

        let frames = try await readFrames(videoURL)
        #expect(frames.map(\.color) == [.blue])
    }

    @Test
    func aResumeFrameRefusedBecauseTheInputIsNotReadyIsRetried() async throws {
        let clock = RecordingPauseClock()
        let (session, videoURL) = try await startPausable(clock: clock)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        try deliver(session, at: 1.0, .complete, .blue)
        pause(clock, at: 1.05)
        try deliver(session, at: 1.5, .complete, .white)
        resume(clock, at: 3.05)
        let ready = Flag(false)
        session.setInputReadyForTesting { ready.value }
        try deliver(session, at: 3.2, .idle)
        #expect(session.frameCountForTesting == 1)

        ready.value = true
        let deadline = Date().addingTimeInterval(2)
        while session.frameCountForTesting < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.frameCountForTesting == 2)
        clock.close(at: { Self.raw(3.5) })
        await session.stop()

        let frames = try await readFrames(videoURL)
        #expect(frames.map(\.color) == [.blue, .white])
        expectTimes(frames, [0, 0.05])
    }

    @Test
    func theNoFramesTimeoutDoesNotRunWhilePausedAndStartsOverOnResume() async throws {
        let clock = RecordingPauseClock()
        let (session, videoURL) = try await startPausable(clock: clock, timeout: .milliseconds(400))
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let errors = Counter()
        session.onError = { _ in errors.increment() }

        clock.pause(at: { HostNanoseconds(machTicks: mach_absolute_time()) })
        session.recordingDidPause()
        try await Task.sleep(for: .milliseconds(700))
        #expect(errors.value == 0)

        clock.resume(at: { HostNanoseconds(machTicks: mach_absolute_time()) })
        session.recordingDidResume()
        try await Task.sleep(for: .milliseconds(200))
        #expect(errors.value == 0)
        try await Task.sleep(for: .milliseconds(600))
        #expect(errors.value == 1)
        await session.stop()
    }

    @Test
    func theNoFramesTimeoutWaitsForResumeWhenThePauseWasNotReported() async throws {
        let clock = RecordingPauseClock()
        let (session, videoURL) = try await startPausable(clock: clock, timeout: .milliseconds(300))
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let errors = Counter()
        session.onError = { _ in errors.increment() }

        clock.pause(at: { HostNanoseconds(machTicks: mach_absolute_time()) })
        try await Task.sleep(for: .milliseconds(600))
        #expect(errors.value == 0)
        await session.stop()
    }

    @Test
    func resumeDoesNotStartTheTimeoutAfterAFrameWasWritten() async throws {
        let clock = RecordingPauseClock()
        let (session, videoURL) = try await startPausable(clock: clock, timeout: .milliseconds(200))
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let errors = Counter()
        session.onError = { _ in errors.increment() }

        let now = HostNanoseconds(machTicks: mach_absolute_time())
        session.processSampleBufferForTesting(try makeVideoSampleBuffer(hostTimeNanos: Int64(now.nanoseconds), status: .complete))
        clock.pause(at: { HostNanoseconds(machTicks: mach_absolute_time()) })
        session.recordingDidPause()
        clock.resume(at: { HostNanoseconds(machTicks: mach_absolute_time()) })
        session.recordingDidResume()
        try await Task.sleep(for: .milliseconds(500))
        #expect(errors.value == 0)
        await session.stop()
    }

    @Test
    func theSessionEndsAtTheAdjustedStopTime() async throws {
        let clock = RecordingPauseClock()
        let (session, videoURL) = try await startPausable(clock: clock)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        try deliver(session, at: 1.0, .complete, .blue)
        pause(clock, at: 1.1)
        resume(clock, at: 2.1)
        try deliver(session, at: 2.2, .complete, .green)
        clock.close(at: { Self.raw(2.6) })
        await session.stop()

        #expect(abs(try await videoDuration(videoURL) - 0.6) < 0.02)
    }

    @Test
    func theSessionEndsAtThePauseStartWhenStoppedWhilePaused() async throws {
        let clock = RecordingPauseClock()
        let (session, videoURL) = try await startPausable(clock: clock)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        try deliver(session, at: 1.0, .complete, .blue)
        try deliver(session, at: 1.05, .complete, .green)
        pause(clock, at: 1.3)
        try deliver(session, at: 1.5, .complete, .red)
        clock.close(at: { Self.raw(2.0) })
        await session.stop()

        #expect(abs(try await videoDuration(videoURL) - 0.3) < 0.02)
        #expect(try await readFrames(videoURL).map(\.color) == [.blue, .green])
    }

    /// Pauses before the first frame and between frames. Paused frames are red.
    private func recordAcrossPauses(clock: RecordingPauseClock) async throws -> (ScreenCaptureSession, URL, [(raw: Double, color: FrameColor)]) {
        let (session, videoURL) = try await startPausable(clock: clock)
        pause(clock, at: 0.9)
        try deliver(session, at: 0.95, .complete, .red)
        try deliver(session, at: 1.2, .complete, .red)
        resume(clock, at: 1.4)
        try deliver(session, at: 1.5, .complete, .blue)
        try deliver(session, at: 1.7, .complete, .green)
        pause(clock, at: 1.8)
        try deliver(session, at: 2.0, .complete, .red)
        try deliver(session, at: 2.5, .complete, .red)
        resume(clock, at: 3.0)
        try deliver(session, at: 3.1, .complete, .white)
        pause(clock, at: 3.2)
        try deliver(session, at: 3.3, .complete, .red)
        resume(clock, at: 3.6)
        try deliver(session, at: 3.7, .complete, .yellow)
        pause(clock, at: 3.9)
        try deliver(session, at: 4.0, .complete, .red)
        clock.close(at: { Self.raw(4.2) })
        await session.stop()
        return (session, videoURL, [(1.5, .blue), (1.7, .green), (3.1, .white), (3.7, .yellow)])
    }

    @Test
    func theMuxLinesUpWithTheMixdownAfterSeveralPauses() async throws {
        let clock = RecordingPauseClock()
        let (session, tmpURL, expected) = try await recordAcrossPauses(clock: clock)
        let folder = tmpURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tmpURL)
            try? FileManager.default.removeItem(at: folder)
        }
        let timeline = clock.timeline
        let videoStart = try #require(session.videoStartHostTime)
        #expect(videoStart == timeline.adjusted(Self.raw(1.5)))

        // The mixdown starts at the microphone's first kept sample, captured before the first pause.
        let audioAnchor = try #require(timeline.adjusted(Self.raw(0.5)))
        let mixdownURL = folder.appendingPathComponent("mixdown.wav")
        try writeSilence(to: mixdownURL, seconds: 4)
        let instruction = try #require(ScreenVideoMuxer.makeTimelineAudioInstructions(
            timelineAudioURL: mixdownURL, audioAnchorHostTime: audioAnchor, videoStartHostTime: videoStart
        ).first)

        let finalURL = folder.appendingPathComponent("screen.mov")
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let recording = RecordingSession(
            createdAt: .now, duration: 3, micAudioURL: mixdownURL.path, title: "Paused", status: .recorded
        )
        context.insert(recording)
        try context.save()
        await ScreenVideoMuxer(workspaceService: MockWorkspaceService(), modelContainer: container).runMux(
            request: ScreenVideoMuxRequest(
                sessionID: recording.id, screenTmpURL: tmpURL, screenVideoURL: finalURL, micURL: mixdownURL,
                appURL: nil, micStartHostTime: audioAnchor, appStartHostTime: nil, videoStartHostTime: videoStart,
                timelineAudioURL: mixdownURL, audioAnchorHostTime: audioAnchor
            )
        )

        let frames = try await readFrames(finalURL)
        #expect(frames.map(\.color) == expected.map(\.color))
        for (frame, capture) in zip(frames, expected) {
            let adjusted = try #require(timeline.adjusted(Self.raw(capture.raw)))
            // Where the mixdown sample captured with this frame lands in the final movie.
            let audioTime = instruction.insertionTime.seconds - instruction.sourceStart.seconds
                + adjusted.seconds(since: audioAnchor)
            #expect(abs(frame.time - audioTime) < 0.002)
        }
    }

    @Test
    func pausedImagesAreAbsentFromTheTemporaryMovie() async throws {
        let clock = RecordingPauseClock()
        let (_, tmpURL, expected) = try await recordAcrossPauses(clock: clock)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let frames = try await readFrames(tmpURL)
        #expect(frames.map(\.color) == expected.map(\.color))
        #expect(!frames.contains { $0.color == .red })
    }

    private static let displayID: CGDirectDisplayID = 1

    private func makeSession(stream: FakeScreenStream, frameDeliveryTimeout: Duration = .seconds(5)) -> ScreenCaptureSession {
        ScreenCaptureSession(
            displayProvider: {
                [ScreenCaptureSession.CapturableDisplay(displayID: Self.displayID, width: 64, height: 64, makeFilter: { SCContentFilter() })]
            },
            streamFactory: { _, _, _, _, _ in stream },
            frameDeliveryTimeout: frameDeliveryTimeout
        )
    }

    private func temporaryMovieURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
    }

    private func expectTimes(_ frames: [WrittenFrame], _ expected: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(frames.count == expected.count, sourceLocation: sourceLocation)
        for (frame, time) in zip(frames, expected) {
            #expect(abs(frame.time - time) < 0.001, "frame at \(frame.time), expected \(time)", sourceLocation: sourceLocation)
        }
    }

    private func videoDuration(_ url: URL) async throws -> Double {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        return try await track.load(.timeRange).duration.seconds
    }

    /// The frames of a movie in order, with their time from the first one and their colour.
    private func readFrames(_ url: URL) async throws -> [WrittenFrame] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(output)
        #expect(reader.startReading())
        var frames: [WrittenFrame] = []
        var first: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            first = first ?? time
            frames.append(WrittenFrame(time: (time - first!).seconds, color: try FrameColor.nearest(to: image)))
        }
        return frames
    }

    private func writeSilence(to url: URL, seconds: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func makeVideoSampleBuffer(hostTimeNanos: Int64, status: SCFrameStatus? = nil, color: FrameColor = .blue) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            nil,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "ScreenCaptureSessionTests", code: Int(createStatus))
        }
        color.fill(pixelBuffer)

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw NSError(domain: "ScreenCaptureSessionTests", code: Int(formatStatus))
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: hostTimeNanos, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw NSError(domain: "ScreenCaptureSessionTests", code: Int(sampleStatus))
        }

        if let status {
            let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true))
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(SCStreamFrameInfo.status.rawValue as CFString).toOpaque(),
                Unmanaged.passUnretained(NSNumber(value: status.rawValue)).toOpaque()
            )
        }

        return sampleBuffer
    }
}

private struct WrittenFrame {
    let time: Double
    let color: FrameColor
}

/// Solid frame colours. Red marks a frame captured during a pause.
private enum FrameColor: CaseIterable {
    case blue, green, red, white, yellow

    /// Blue, green, red.
    var bgr: (UInt8, UInt8, UInt8) {
        switch self {
        case .blue: (220, 30, 30)
        case .green: (30, 220, 30)
        case .red: (30, 30, 220)
        case .white: (230, 230, 230)
        case .yellow: (30, 220, 220)
        }
    }

    func fill(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<CVPixelBufferGetHeight(pixelBuffer) {
            for column in 0..<CVPixelBufferGetWidth(pixelBuffer) {
                let pixel = base + row * bytesPerRow + column * 4
                (pixel[0], pixel[1], pixel[2], pixel[3]) = (bgr.0, bgr.1, bgr.2, 255)
            }
        }
    }

    /// The colour closest to the centre pixel of a decoded BGRA image.
    static func nearest(to pixelBuffer: CVPixelBuffer) throws -> FrameColor {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let pixel = base + (CVPixelBufferGetHeight(pixelBuffer) / 2) * CVPixelBufferGetBytesPerRow(pixelBuffer)
            + (CVPixelBufferGetWidth(pixelBuffer) / 2) * 4
        func distance(_ color: FrameColor) -> Int {
            let (b, g, r) = color.bgr
            return abs(Int(pixel[0]) - Int(b)) + abs(Int(pixel[1]) - Int(g)) + abs(Int(pixel[2]) - Int(r))
        }
        return try #require(allCases.min { distance($0) < distance($1) })
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Error?

    var value: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class FakeScreenStream: ScreenCaptureStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var storedStopCount = 0
    var onStart: (() -> Void)?

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStopCount
    }

    func startCapture() async throws {
        onStart?()
    }

    func stopCapture() async throws {
        lock.withLock { storedStopCount += 1 }
    }
}

/// Holds a frame append open on the sample queue so a test can stop the session mid-append.
private final class AppendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var left = false

    var didLeave: Bool {
        lock.lock()
        defer { lock.unlock() }
        return left
    }

    func enterAndHold(for seconds: TimeInterval) {
        lock.lock()
        entered = true
        lock.unlock()
        Thread.sleep(forTimeInterval: seconds)
        lock.lock()
        left = true
        lock.unlock()
    }

    func waitUntilEntered() async {
        while true {
            let hasEntered = lock.withLock { entered }
            if hasEntered {
                return
            }
            await Task.yield()
        }
    }
}
