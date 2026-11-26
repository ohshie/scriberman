import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// @unchecked Sendable: all mutable state protected by NSLock and internal DispatchQueue
final class AppAudioStreamOutputHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var fileURL: URL?
    /// Injected so a mid-session capture restart can rebuild the stream and its handlers while
    /// continuing to write into the same file, with its accumulated timing segments intact.
    let streamer: AudioFileStreamer
    private let gate: CaptureAudioGate
    private var monoFormat: AVAudioFormat?
    private var conversion: GatedAudioConversion?
    private var firstBufferHostTime: HostNanoseconds?
    private let liveAudioContinuation: AsyncStream<LiveAudioChunk>.Continuation?
    var onFirstBufferHostTime: (@Sendable (HostNanoseconds) -> Void)?
    private let layoutTracker = UnsupportedPCMLayoutTracker(source: "app")

    /// Buffers dropped because their sample layout cannot be copied.
    var unsupportedFormatCount: Int { layoutTracker.unsupportedFormatCount }

    /// Distinct unsupported formats logged.
    var loggedUnsupportedFormatCount: Int { layoutTracker.loggedFormatCount }

    var audioLevel: Float {
        streamer.audioLevel
    }

    /// When app audio last produced sustained activity (see `CaptureActivityTracker`).
    var lastActivityAt: Date? {
        streamer.lastActivityAt
    }

    /// Frames successfully written to this source's file since capture started. Counts buffers
    /// landed, not sound detected, so silence still advances it.
    var framesWritten: Int64 { streamer.framesWritten }

    /// Write failures observed since capture started.
    var writeFailureCount: Int { streamer.writeFailureCount }

    private var hasPrepared = false

    init(
        liveAudioContinuation: AsyncStream<LiveAudioChunk>.Continuation? = nil,
        streamer: AudioFileStreamer = AudioFileStreamer(label: "app"),
        gate: CaptureAudioGate = CaptureAudioGate()
    ) {
        self.liveAudioContinuation = liveAudioContinuation
        self.streamer = streamer
        self.gate = gate
        super.init()
    }

    /// Adopts a writer that is already open and mid-recording. See the mic handler for why a
    /// restart must not re-prepare.
    func adoptPreparedOutput(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        self.fileURL = url
        self.monoFormat = nil
        self.conversion = nil
        self.firstBufferHostTime = nil
        self.hasPrepared = true
    }

    func configureOutput(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        self.fileURL = url
        self.monoFormat = nil
        self.conversion = nil
        self.firstBufferHostTime = nil
        self.hasPrepared = false
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
        guard outputType == .audio else {
            return
        }
        process(sampleBuffer)
    }

#if DEBUG
    /// Test seam: feed a sample buffer without an `SCStream`, which cannot be constructed in tests.
    func processSampleBufferForTesting(_ sampleBuffer: CMSampleBuffer) {
        process(sampleBuffer)
    }
#endif

    private func process(_ sampleBuffer: CMSampleBuffer) {
        gate.recordArrival()
        guard layoutTracker.admit(sampleBuffer) else {
            return
        }
        captureFirstBufferHostTimeIfNeeded(from: sampleBuffer)
        let hostTime = HostNanoseconds(presentationTimeOf: sampleBuffer)

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
            conversion = monoFormat.map {
                GatedAudioConversion(converter: nil, targetFormat: $0, gate: gate)
            }
        }

        guard let fileURL, let monoFormat, let conversion else {
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

        conversion.process(monoBuffer, hostTime: hostTime) { event in
            switch event {
            case .audio(let audio):
                streamer.write(buffer: audio.buffer, hostTimeNanos: audio.hostTime?.nanoseconds)
                guard let liveHostTime = audio.hostTime else { return }
                liveAudioContinuation?.yield(LiveAudioChunk(
                    samples: AudioDownmixer.toMono(buffer: audio.buffer),
                    source: .app,
                    sampleRate: format.sampleRate,
                    hostTime: liveHostTime,
                    rawHostTime: audio.rawHostTime
                ))
            case .pauseMarker(let number):
                liveAudioContinuation?.yield(.pauseMarker(number, source: .app))
            }
        }
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
        let callback: (@Sendable (HostNanoseconds) -> Void)?
        let hostTimeToEmit: HostNanoseconds?
        var didCaptureFirstHostTime = false

        lock.lock()
        if firstBufferHostTime == nil,
           let hostTime = HostNanoseconds(presentationTimeOf: sampleBuffer),
           let firstKept = gate.firstKeptHostTime(
               startingAt: hostTime,
               frameCount: CMSampleBufferGetNumSamples(sampleBuffer),
               sampleRate: sampleBuffer.sampleRate
           ) {
            firstBufferHostTime = firstKept
            didCaptureFirstHostTime = true
        }
        callback = onFirstBufferHostTime
        hostTimeToEmit = didCaptureFirstHostTime ? firstBufferHostTime : nil
        lock.unlock()

        if let hostTimeToEmit {
            callback?(hostTimeToEmit)
        }
    }
}
