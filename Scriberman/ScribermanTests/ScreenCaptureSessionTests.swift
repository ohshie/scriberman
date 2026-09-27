import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Testing
@testable import Scriberman

final class ScreenCaptureSessionTests {
    @Test
    func testStartThrowsWhenDisplayIsNotAvailable() async throws {
        let session = ScreenCaptureSession(displayProvider: { [] })

        await #expect(throws: RecordingError.self) {
            try await session.start(
                displayID: 42,
                videoURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
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

        try await session.start(displayID: Self.displayID, videoURL: videoURL)

        #expect(session.frameCountForTesting == 1)
        #expect(session.videoStartHostTime == HostNanoseconds(nanoseconds: 1_000_000_000))
        await session.stop()
    }

    @Test
    func testFirstWrittenFrameSetsTheAnchorAndLaterFramesDoNot() async throws {
        let session = makeSession(stream: FakeScreenStream())
        let videoURL = temporaryMovieURL()
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try await session.start(displayID: Self.displayID, videoURL: videoURL)

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
        try await session.start(displayID: Self.displayID, videoURL: videoURL)

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
        try await session.start(displayID: Self.displayID, videoURL: videoURL)

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

        try await session.start(displayID: Self.displayID, videoURL: firstURL)
        let staleGeneration = session.generationForTesting
        await session.stop()
        try await session.start(displayID: Self.displayID, videoURL: secondURL)

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
        try await session.start(displayID: Self.displayID, videoURL: videoURL)
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

    private static let displayID: CGDirectDisplayID = 1

    private func makeSession(stream: FakeScreenStream) -> ScreenCaptureSession {
        ScreenCaptureSession(
            displayProvider: {
                [ScreenCaptureSession.CapturableDisplay(displayID: Self.displayID, width: 64, height: 64, makeFilter: { SCContentFilter() })]
            },
            streamFactory: { _, _, _, _, _ in stream }
        )
    }

    private func temporaryMovieURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
    }

    private func makeVideoSampleBuffer(hostTimeNanos: Int64, status: SCFrameStatus? = nil) throws -> CMSampleBuffer {
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
