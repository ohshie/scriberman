import CoreMedia
import CoreVideo
import Foundation
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

    @Test
    func testVideoStartHostTimeCapturesFirstFrameOnly() throws {
        let session = ScreenCaptureSession(displayProvider: { [] })
        let firstSample = try makeVideoSampleBuffer(hostTimeNanos: 1_111_000_000)
        let secondSample = try makeVideoSampleBuffer(hostTimeNanos: 2_222_000_000)

        session.captureVideoStartHostTimeIfNeeded(from: firstSample)
        session.captureVideoStartHostTimeIfNeeded(from: secondSample)

        #expect(session.videoStartHostTime == HostNanoseconds(nanoseconds: 1_111_000_000))
    }

    @Test
    func testPresentationTimeConvertsToNanoseconds() throws {
        let sample = try makeVideoSampleBuffer(hostTimeNanos: 2_500_000_000)

        #expect(HostNanoseconds(presentationTimeOf: sample) == HostNanoseconds(nanoseconds: 2_500_000_000))
    }

    private func makeVideoSampleBuffer(hostTimeNanos: Int64) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            nil,
            4,
            4,
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
