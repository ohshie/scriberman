import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// @unchecked Sendable: all mutable state protected by NSLock and internal DispatchQueue
final class AppAudioStreamOutputHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var fileURL: URL?
    private let streamer = AudioFileStreamer(label: "app")
    private var monoFormat: AVAudioFormat?
    private var firstBufferHostTime: UInt64?
    private let liveAudioContinuation: AsyncStream<([Float], AudioSource, Double)>.Continuation?
    var onFirstBufferHostTime: (@Sendable (UInt64) -> Void)?

    var audioLevel: Float {
        streamer.audioLevel
    }

    private var hasPrepared = false

    init(liveAudioContinuation: AsyncStream<([Float], AudioSource, Double)>.Continuation? = nil) {
        self.liveAudioContinuation = liveAudioContinuation
        super.init()
    }

    func configureOutput(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        self.fileURL = url
        self.monoFormat = nil
        self.firstBufferHostTime = nil
        self.hasPrepared = false
    }

    func closeOutput() {
        streamer.close()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else {
            return
        }
        process(sampleBuffer)
    }

    private func process(_ sampleBuffer: CMSampleBuffer) {
        captureFirstBufferHostTimeIfNeeded(from: sampleBuffer)
        let bufferHostNanos = Self.hostTimeNanos(from: sampleBuffer)

        guard let pcmBuffer = createPCMBuffer(from: sampleBuffer) else {
            return
        }
        let monoSamples = AudioDownmixer.toMono(buffer: pcmBuffer)
        guard !monoSamples.isEmpty else {
            return
        }

        lock.lock()
        if monoFormat == nil {
            monoFormat = AVAudioFormat(
                standardFormatWithSampleRate: pcmBuffer.format.sampleRate,
                channels: 1
            )
        }

        guard let fileURL, let monoFormat else {
            lock.unlock()
            return
        }

        if !hasPrepared {
            do {
                try streamer.prepare(url: fileURL, format: monoFormat)
                hasPrepared = true
            } catch {
                lock.unlock()
                return
            }
        }

        let format = monoFormat
        lock.unlock()

        guard
            let monoBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(monoSamples.count)
            ),
            let channelData = monoBuffer.floatChannelData
        else {
            return
        }

        monoBuffer.frameLength = AVAudioFrameCount(monoSamples.count)
        monoSamples.withUnsafeBufferPointer { source in
            if let sourceBaseAddress = source.baseAddress {
                channelData[0].update(from: sourceBaseAddress, count: monoSamples.count)
            }
        }

        streamer.write(buffer: monoBuffer, hostTimeNanos: bufferHostNanos)
        liveAudioContinuation?.yield((monoSamples, .app, format.sampleRate))
    }

    /// Host time (nanoseconds) of a sample buffer's first frame, or nil if unavailable.
    private static func hostTimeNanos(from sampleBuffer: CMSampleBuffer) -> UInt64? {
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTimeClock = CMClockGetHostTimeClock()
        let hostTime = CMSyncConvertTime(presentationTimestamp, from: hostTimeClock, to: hostTimeClock)
        guard CMTIME_IS_VALID(hostTime), CMTIME_IS_NUMERIC(hostTime) else { return nil }
        return HostClock.nanoseconds(machTime: CMClockConvertHostTimeToSystemUnits(hostTime))
    }

    private func createPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        guard let format = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(numSamples)
        ) else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        var requiredSize = 0
        let queryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard queryStatus == noErr, requiredSize > 0 else {
            return nil
        }

        let audioBufferListRawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { audioBufferListRawPtr.deallocate() }

        let audioBufferListPtr = audioBufferListRawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        let audioBufferList = UnsafeMutableAudioBufferListPointer(audioBufferListPtr)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPtr,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            return nil
        }

        if let channelData = pcmBuffer.floatChannelData {
            let channelCount = Int(format.channelCount)
            for channel in 0..<min(audioBufferList.count, channelCount) {
                let audioBuffer = audioBufferList[channel]
                if let sourceData = audioBuffer.mData?.assumingMemoryBound(to: Float.self) {
                    channelData[channel].initialize(from: sourceData, count: Int(pcmBuffer.frameLength))
                }
            }
        }

        return pcmBuffer
    }

    private func captureFirstBufferHostTimeIfNeeded(from sampleBuffer: CMSampleBuffer) {
        let callback: (@Sendable (UInt64) -> Void)?
        let hostTimeToEmit: UInt64?
        var didCaptureFirstHostTime = false

        lock.lock()
        if firstBufferHostTime == nil {
            let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let hostTimeClock = CMClockGetHostTimeClock()
            let hostTime = CMSyncConvertTime(
                presentationTimestamp,
                from: hostTimeClock,
                to: hostTimeClock
            )

            if CMTIME_IS_VALID(hostTime), CMTIME_IS_NUMERIC(hostTime) {
                firstBufferHostTime = CMClockConvertHostTimeToSystemUnits(hostTime)
                didCaptureFirstHostTime = true
            }
        }
        callback = onFirstBufferHostTime
        hostTimeToEmit = didCaptureFirstHostTime ? firstBufferHostTime : nil
        lock.unlock()

        if let hostTimeToEmit {
            callback?(hostTimeToEmit)
        }
    }
}
