import AVFoundation
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

/// Stream output for the microphone track of a unified `SCStream` (macOS 15+
/// `captureMicrophone`). Microphone buffers arrive in the device's native format; this
/// converts them to the common 48 kHz mono timeline, writes them (with per-buffer host
/// time for the timing sidecar), and feeds the live audio stream. Because both mic and
/// app come from one `SCStream`, their presentation timestamps share a clock reference.
///
/// @unchecked Sendable: mutable state is protected by `lock` and the streamer's queue.
final class MicStreamOutputHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    /// Injected so a mid-session capture restart can rebuild the stream and its handlers while
    /// continuing to write into the same file, with its accumulated timing segments intact.
    let streamer: AudioFileStreamer
    private let liveAudioContinuation: AsyncStream<LiveAudioChunk>.Continuation?
    private let targetFormat: AVAudioFormat
    private var fileURL: URL?
    private let gate: CaptureAudioGate
    private var conversion: GatedAudioConversion?
    private var converterSourceFormat: AVAudioFormat?
    private var firstBufferHostTime: HostNanoseconds?
    private var hasPrepared = false
    private let layoutTracker = UnsupportedPCMLayoutTracker(source: "mic")

    var onFirstBufferHostTime: (@Sendable (HostNanoseconds) -> Void)?

    /// Buffers dropped because their sample layout cannot be copied.
    var unsupportedFormatCount: Int { layoutTracker.unsupportedFormatCount }

    /// Distinct unsupported formats logged.
    var loggedUnsupportedFormatCount: Int { layoutTracker.loggedFormatCount }

    var audioLevel: Float { streamer.audioLevel }

    /// When the microphone last produced sustained activity (see `CaptureActivityTracker`).
    var lastActivityAt: Date? { streamer.lastActivityAt }

    /// Frames successfully written to this source's file since capture started. Counts buffers
    /// landed, not sound detected, so silence still advances it.
    var framesWritten: Int64 { streamer.framesWritten }

    /// Write failures observed since capture started.
    var writeFailureCount: Int { streamer.writeFailureCount }

    init(
        liveAudioContinuation: AsyncStream<LiveAudioChunk>.Continuation? = nil,
        streamer: AudioFileStreamer = AudioFileStreamer(label: "mic"),
        gate: CaptureAudioGate = CaptureAudioGate()
    ) {
        self.liveAudioContinuation = liveAudioContinuation
        self.streamer = streamer
        self.gate = gate
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        super.init()
    }

    func configureOutput(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        fileURL = url
        conversion = nil
        converterSourceFormat = nil
        firstBufferHostTime = nil
        hasPrepared = false
    }

    /// Adopts a writer that is already open and mid-recording, so a restart neither re-prepares
    /// it (which would truncate the file and discard its timing segments) nor writes a
    /// `.timing` sidecar early.
    func adoptPreparedOutput(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        fileURL = url
        conversion = nil
        converterSourceFormat = nil
        firstBufferHostTime = nil
        hasPrepared = true
    }

    /// True once the writer is open: prepared on the first buffer, or adopted from a predecessor.
    var isOutputPrepared: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasPrepared
    }

    func closeOutput() {
        streamer.close()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .microphone else {
            return
        }
        process(sampleBuffer)
    }

#if DEBUG
    /// Test seam: feed a sample buffer without an `SCStream`, which cannot be constructed in
    /// tests (it needs live `SCShareableContent`, a capturable window, and TCC grants).
    func processSampleBufferForTesting(_ sampleBuffer: CMSampleBuffer) {
        process(sampleBuffer)
    }
#endif

    private func process(_ sampleBuffer: CMSampleBuffer) {
        gate.recordArrival()
        guard layoutTracker.admit(sampleBuffer) else {
            return
        }
        let hostTime = HostNanoseconds(presentationTimeOf: sampleBuffer)
        captureFirstBufferHostTimeIfNeeded(hostTime.flatMap {
            gate.firstKeptHostTime(
                startingAt: $0,
                frameCount: CMSampleBufferGetNumSamples(sampleBuffer),
                sampleRate: sampleBuffer.sampleRate
            )
        })

        guard let nativeBuffer = Self.makePCMBuffer(from: sampleBuffer) else {
            return
        }

        lock.lock()
        if conversion == nil || converterSourceFormat != nativeBuffer.format {
            conversion = AVAudioConverter(from: nativeBuffer.format, to: targetFormat).map {
                GatedAudioConversion(converter: $0, targetFormat: targetFormat, gate: gate)
            }
            converterSourceFormat = nativeBuffer.format
        }
        guard let fileURL, let conversion else {
            lock.unlock()
            return
        }
        if !hasPrepared {
            do {
                try streamer.prepare(url: fileURL, format: targetFormat)
                hasPrepared = true
            } catch {
                lock.unlock()
                return
            }
        }
        lock.unlock()

        conversion.process(nativeBuffer, hostTime: hostTime) { event in
            switch event {
            case .audio(let audio):
                CaptureTrace.noteConverted(audio.buffer, hostTime: audio.hostTime)
                streamer.write(buffer: audio.buffer, hostTimeNanos: audio.hostTime?.nanoseconds)
                guard let liveHostTime = audio.hostTime else { return }
                let monoSamples = AudioDownmixer.toMono(buffer: audio.buffer)
                if !monoSamples.isEmpty {
                    liveAudioContinuation?.yield(LiveAudioChunk(
                        samples: monoSamples,
                        source: .mic,
                        sampleRate: targetFormat.sampleRate,
                        hostTime: liveHostTime,
                        rawHostTime: audio.rawHostTime
                    ))
                }
            case .pauseMarker(let number):
                liveAudioContinuation?.yield(.pauseMarker(number, source: .mic))
            }
        }
    }

    private func captureFirstBufferHostTimeIfNeeded(_ hostTime: HostNanoseconds?) {
        guard let hostTime else { return }
        var didCapture = false
        lock.lock()
        if firstBufferHostTime == nil {
            firstBufferHostTime = hostTime
            didCapture = true
        }
        let callback = onFirstBufferHostTime
        lock.unlock()
        if didCapture {
            callback?(hostTime)
        }
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        var blockBuffer: CMBlockBuffer?
        var requiredSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        ) == noErr, requiredSize > 0 else {
            return nil
        }

        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }
        let listPtr = rawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)

        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPtr,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr else {
            return nil
        }

        let list = UnsafeMutableAudioBufferListPointer(listPtr)
        if let channelData = pcmBuffer.floatChannelData {
            let channelCount = Int(format.channelCount)
            for channel in 0..<min(list.count, channelCount) {
                if let sourceData = list[channel].mData?.assumingMemoryBound(to: Float.self) {
                    channelData[channel].initialize(from: sourceData, count: Int(pcmBuffer.frameLength))
                }
            }
        }
        return pcmBuffer
    }
}

extension CMSampleBuffer {
    /// Sample rate of the buffer's audio format, or 0 when it has none.
    var sampleRate: Double {
        CMSampleBufferGetFormatDescription(self)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 0
    }
}

/// Counts ScreenCaptureKit audio buffers whose sample layout the capture handlers cannot copy.
///
/// The handlers copy Float32 samples one channel buffer at a time. That covers non-interleaved
/// buffers of any channel count and mono buffers flagged as interleaved, whose single channel has
/// the same memory layout either way. Any other layout would come out as an empty or partial
/// buffer, so it is counted and logged, once per format, instead of written.
final class UnsupportedPCMLayoutTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let source: String
    private let logger = Logger(subsystem: "Scriberman", category: "CapturePCMLayout")
    private var count = 0
    private var loggedFormats: Set<String> = []

    init(source: String) {
        self.source = source
    }

    var unsupportedFormatCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Distinct unsupported formats seen, each of which was logged once.
    var loggedFormatCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loggedFormats.count
    }

    static func isSupported(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32 && (!format.isInterleaved || format.channelCount == 1)
    }

    /// True when the buffer can be copied. Otherwise the buffer is counted and false is returned.
    func admit(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd)
        else {
            return true
        }
        if Self.isSupported(format) {
            return true
        }

        // Built from the format's fields: `AVAudioFormat.description` includes the object's
        // address, which differs for every buffer.
        let formatKey = "commonFormat=\(format.commonFormat.rawValue) channels=\(format.channelCount) sampleRate=\(format.sampleRate) interleaved=\(format.isInterleaved)"
        lock.lock()
        count += 1
        let isFirstOfFormat = loggedFormats.insert(formatKey).inserted
        lock.unlock()
        if isFirstOfFormat {
            logger.error(
                "Unsupported \(self.source, privacy: .public) sample layout; buffers are not written. \(formatKey, privacy: .public)"
            )
        }
        return false
    }
}
