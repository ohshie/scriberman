import AVFoundation
import CoreMedia
import Foundation
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
    private let streamer = AudioFileStreamer(label: "mic")
    private let liveAudioContinuation: AsyncStream<([Float], AudioSource, Double)>.Continuation?
    private let targetFormat: AVAudioFormat
    private var fileURL: URL?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var firstBufferHostTime: UInt64?
    private var hasPrepared = false

    var onFirstBufferHostTime: (@Sendable (UInt64) -> Void)?

    var audioLevel: Float { streamer.audioLevel }

    /// When the microphone last produced sustained activity (see `CaptureActivityTracker`).
    var lastActivityAt: Date? { streamer.lastActivityAt }

    init(liveAudioContinuation: AsyncStream<([Float], AudioSource, Double)>.Continuation? = nil) {
        self.liveAudioContinuation = liveAudioContinuation
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
        converter = nil
        converterSourceFormat = nil
        firstBufferHostTime = nil
        hasPrepared = false
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

    private func process(_ sampleBuffer: CMSampleBuffer) {
        let hostNanos = Self.hostTimeNanos(from: sampleBuffer)
        captureFirstBufferHostTimeIfNeeded(hostNanos)

        guard let nativeBuffer = Self.makePCMBuffer(from: sampleBuffer) else {
            return
        }

        lock.lock()
        if converter == nil || converterSourceFormat != nativeBuffer.format {
            converter = AVAudioConverter(from: nativeBuffer.format, to: targetFormat)
            converterSourceFormat = nativeBuffer.format
        }
        guard let fileURL, let converter else {
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

        guard let converted = Self.convert(nativeBuffer, with: converter, to: targetFormat),
              converted.frameLength > 0 else {
            return
        }

        streamer.write(buffer: converted, hostTimeNanos: hostNanos)
        let monoSamples = AudioDownmixer.toMono(buffer: converted)
        if !monoSamples.isEmpty {
            liveAudioContinuation?.yield((monoSamples, .mic, targetFormat.sampleRate))
        }
    }

    private func captureFirstBufferHostTimeIfNeeded(_ hostNanos: UInt64?) {
        guard let hostNanos else { return }
        var didCapture = false
        lock.lock()
        if firstBufferHostTime == nil {
            firstBufferHostTime = hostNanos
            didCapture = true
        }
        let callback = onFirstBufferHostTime
        lock.unlock()
        if didCapture {
            callback?(hostNanos)
        }
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32, 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        // Feed the input buffer exactly once per convert() call. Returning it again when the
        // converter asks for more input duplicates frames into the output (observed as a
        // constant per-buffer surplus that time-stretches the whole channel).
        var didProvideInput = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return output.frameLength > 0 ? output : nil
        default:
            return nil
        }
    }

    private static func hostTimeNanos(from sampleBuffer: CMSampleBuffer) -> UInt64? {
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTimeClock = CMClockGetHostTimeClock()
        let hostTime = CMSyncConvertTime(presentationTimestamp, from: hostTimeClock, to: hostTimeClock)
        guard CMTIME_IS_VALID(hostTime), CMTIME_IS_NUMERIC(hostTime) else { return nil }
        return HostClock.nanoseconds(machTime: CMClockConvertHostTimeToSystemUnits(hostTime))
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
