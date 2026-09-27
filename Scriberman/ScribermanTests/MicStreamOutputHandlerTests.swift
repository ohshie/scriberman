import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Scriberman

/// Covers what happens to the microphone track of a unified capture stream when the device is
/// swapped mid-recording: the incoming native format changes, and the handler must adapt without
/// re-anchoring the timeline or reopening its output file.
struct MicStreamOutputHandlerTests {
    private func makeSampleBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frameCount: Int,
        hostTimeNanos: UInt64,
        commonFormat: AVAudioCommonFormat = .pcmFormatFloat32,
        interleaved: Bool = false
    ) throws -> CMSampleBuffer {
        let format = try #require(
            AVAudioFormat(
                commonFormat: commonFormat,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: interleaved
            )
        )
        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        #expect(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            ) == noErr
        )
        let description = try #require(formatDescription)

        let pcmBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        )
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        if commonFormat == .pcmFormatFloat32, !interleaved {
            for channel in 0..<Int(channels) {
                let data = try #require(pcmBuffer.floatChannelData)[channel]
                for frame in 0..<frameCount {
                    // A non-silent, non-constant signal so the level meter and activity tracker move.
                    data[frame] = sinf(Float(frame) * 0.05) * 0.5
                }
            }
        }

        let presentationTime = CMTime(
            value: CMTimeValue(hostTimeNanos),
            timescale: CMTimeScale(NSEC_PER_SEC)
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        #expect(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: false,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: description,
                sampleCount: CMItemCount(frameCount),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            ) == noErr
        )
        let buffer = try #require(sampleBuffer)
        #expect(
            CMSampleBufferSetDataBufferFromAudioBufferList(
                buffer,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                bufferList: pcmBuffer.audioBufferList
            ) == noErr
        )
        return buffer
    }

    @Test
    func testAppHandlerRejectsInt16Buffers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("app.wav")

        let anchors = AnchorRecorder()
        let handler = AppAudioStreamOutputHandler()
        handler.onFirstBufferHostTime = { anchors.record($0.nanoseconds) }
        handler.configureOutput(url: appURL)

        handler.processSampleBufferForTesting(
            try makeSampleBuffer(sampleRate: 48_000, channels: 1, frameCount: 480, hostTimeNanos: 1_000_000_000, commonFormat: .pcmFormatInt16)
        )
        handler.closeOutput()

        #expect(handler.unsupportedFormatCount == 1)
        #expect(anchors.values.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: appURL.path))
    }

    @Test
    func testMicHandlerRejectsInterleavedStereoBuffers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let micURL = root.appendingPathComponent("mic.wav")

        let anchors = AnchorRecorder()
        let handler = MicStreamOutputHandler()
        handler.onFirstBufferHostTime = { anchors.record($0.nanoseconds) }
        handler.configureOutput(url: micURL)

        let interleaved = try makeSampleBuffer(
            sampleRate: 48_000, channels: 2, frameCount: 480, hostTimeNanos: 1_000_000_000, interleaved: true
        )
        handler.processSampleBufferForTesting(interleaved)
        handler.processSampleBufferForTesting(interleaved)

        #expect(handler.unsupportedFormatCount == 2)
        #expect(handler.loggedUnsupportedFormatCount == 1)
        #expect(anchors.values.isEmpty)

        // A supported buffer afterwards is written and anchors the timeline.
        handler.processSampleBufferForTesting(
            try makeSampleBuffer(sampleRate: 48_000, channels: 2, frameCount: 480, hostTimeNanos: 1_010_000_000)
        )
        handler.closeOutput()

        #expect(handler.unsupportedFormatCount == 2)
        #expect(anchors.values == [1_010_000_000])
        #expect(try AVAudioFile(forReading: micURL).length > 0)
    }

    /// ScreenCaptureKit delivers some mono microphone buffers flagged as interleaved. One channel has
    /// the same layout either way, so these must be written, not rejected.
    @Test
    func testMonoBuffersFlaggedInterleavedAreWritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let micURL = root.appendingPathComponent("mic.wav")
        let appURL = root.appendingPathComponent("app.wav")

        let micAnchors = AnchorRecorder()
        let mic = MicStreamOutputHandler()
        mic.onFirstBufferHostTime = { micAnchors.record($0.nanoseconds) }
        mic.configureOutput(url: micURL)
        let app = AppAudioStreamOutputHandler()
        app.configureOutput(url: appURL)

        let monoInterleaved = try makeSampleBuffer(
            sampleRate: 48_000, channels: 1, frameCount: 480, hostTimeNanos: 1_000_000_000, interleaved: true
        )
        mic.processSampleBufferForTesting(monoInterleaved)
        app.processSampleBufferForTesting(monoInterleaved)
        mic.closeOutput()
        app.closeOutput()

        #expect(mic.unsupportedFormatCount == 0)
        #expect(app.unsupportedFormatCount == 0)
        #expect(micAnchors.values == [1_000_000_000])
        #expect(try AVAudioFile(forReading: micURL).length == 480)
        #expect(try AVAudioFile(forReading: appURL).length == 480)
    }

    @Test
    func testAppHandlerReportsFirstBufferHostTimeInNanoseconds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let anchors = AnchorRecorder()
        let handler = AppAudioStreamOutputHandler()
        handler.onFirstBufferHostTime = { anchors.record($0.nanoseconds) }
        handler.configureOutput(url: root.appendingPathComponent("app.wav"))

        handler.processSampleBufferForTesting(
            try makeSampleBuffer(sampleRate: 48_000, channels: 1, frameCount: 480, hostTimeNanos: 1_500_000_000)
        )
        handler.processSampleBufferForTesting(
            try makeSampleBuffer(sampleRate: 48_000, channels: 1, frameCount: 480, hostTimeNanos: 1_510_000_000)
        )
        handler.closeOutput()

        #expect(anchors.values == [1_500_000_000])
    }

    @Test
    func testNativeFormatChangeMidStreamKeepsOneFileAndOneTimelineAnchor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let micURL = root.appendingPathComponent("mic.wav")

        let anchors = AnchorRecorder()
        let handler = MicStreamOutputHandler()
        handler.onFirstBufferHostTime = { anchors.record($0.nanoseconds) }
        handler.configureOutput(url: micURL)

        // Device A: 44.1 kHz mono.
        let first = try makeSampleBuffer(
            sampleRate: 44_100,
            channels: 1,
            frameCount: 441,
            hostTimeNanos: 1_000_000_000
        )
        handler.processSampleBufferForTesting(first)

        // Device B after a mid-recording swap: 48 kHz stereo, a different native format.
        let second = try makeSampleBuffer(
            sampleRate: 48_000,
            channels: 2,
            frameCount: 480,
            hostTimeNanos: 1_100_000_000
        )
        handler.processSampleBufferForTesting(second)

        handler.closeOutput()

        // Both devices' audio landed in the same file, so the swap did not reopen the output.
        let audioFile = try AVAudioFile(forReading: micURL)
        #expect(audioFile.processingFormat.sampleRate == 48_000)
        #expect(audioFile.length > 0)

        // The timeline anchor is captured once, from the first buffer, and survives the swap.
        #expect(anchors.values == [1_000_000_000])

        // Both buffers are logged as segments against the same sidecar.
        let sidecar = try #require(AudioFileStreamer.loadTimingSidecar(for: micURL))
        #expect(sidecar.sampleRate == 48_000)
        #expect(sidecar.segments.count == 2)
        #expect(sidecar.segments[0].startHostTimeNanos == 1_000_000_000)
        #expect(sidecar.segments[1].startHostTimeNanos == 1_100_000_000)
        #expect(sidecar.totalFrames == Int(audioFile.length))
    }
}

private final class AnchorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt64] = []

    var values: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ value: UInt64) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
