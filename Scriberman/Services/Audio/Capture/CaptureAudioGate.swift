@preconcurrency import AVFoundation
import Foundation

/// One source's view of the recording's pause clock. It belongs to the recording, so every handler
/// the source gets during that recording uses the same one.
///
/// @unchecked Sendable: the counter is guarded by `lock`; `clock` synchronizes itself.
final class CaptureAudioGate: @unchecked Sendable {
    let clock: RecordingPauseClock
    private let lock = NSLock()
    private var _arrivalCount: Int64 = 0

    init(clock: RecordingPauseClock = RecordingPauseClock()) {
        self.clock = clock
    }

    /// Raw buffers delivered by the capture framework, counted before anything is cut. Unlike
    /// `framesWritten` this advances during a pause.
    var arrivalCount: Int64 { lock.withLock { _arrivalCount } }

    func recordArrival() {
        lock.withLock { _arrivalCount += 1 }
    }

    /// Adjusted time of the first kept sample of a raw buffer, or nil when none is kept.
    func firstKeptHostTime(
        startingAt hostTime: HostNanoseconds,
        frameCount: Int,
        sampleRate: Double
    ) -> HostNanoseconds? {
        let timeline = clock.timeline
        // A buffer whose size is unknown is judged by its start.
        guard frameCount > 0, sampleRate > 0 else { return timeline.adjusted(hostTime) }
        let start = Int64(clamping: hostTime.nanoseconds)
        guard let first = timeline.keptRanges(
            startNanos: start, frameCount: frameCount, sampleRate: sampleRate
        ).first else { return nil }
        return HostNanoseconds(startNanos: start, frame: first.frames.lowerBound, sampleRate: sampleRate)
            .removing(first.removedNanos)
    }
}

/// The recording's pause clock and one gate per audio source.
struct RecordingCaptureGates: Sendable {
    let clock: RecordingPauseClock
    let mic: CaptureAudioGate
    let app: CaptureAudioGate

    init(clock: RecordingPauseClock = RecordingPauseClock()) {
        self.clock = clock
        self.mic = CaptureAudioGate(clock: clock)
        self.app = CaptureAudioGate(clock: clock)
    }
}

/// Audio that passed the gate.
struct GatedAudio {
    let buffer: AVAudioPCMBuffer
    /// Adjusted time of the first frame. Nil for a buffer that arrived without a host time, which
    /// the file writer counts and drops, and which must not reach live transcription.
    let hostTime: HostNanoseconds?
    let rawHostTime: HostNanoseconds?
}

/// Converts one capture source's buffers and cuts paused audio out of the result.
///
/// One instance belongs to one converter and is used from one delivery queue.
///
/// A resampling converter holds frames between calls, so the first frames of an output buffer were
/// captured at the end of the previous input buffer. The cut follows each frame's own capture time.
/// Recorded buffer times keep their existing meaning (output frame 0 is stamped with the input
/// buffer's time), so a pause adds neither a gap nor an overlap to a converted source.
final class GatedAudioConversion {
    private let converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private let gate: CaptureAudioGate
    private var inputFrames: Int64 = 0
    private var outputFrames: Int64 = 0
    /// Raw end time of the previous input buffer. Nil when there was none or it had no host time.
    private var previousEndNanos: Int64?

    /// `converter` is nil for a source that already delivers `targetFormat`.
    init(converter: AVAudioConverter?, targetFormat: AVAudioFormat, gate: CaptureAudioGate) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.gate = gate
    }

    func process(_ input: AVAudioPCMBuffer, hostTime: HostNanoseconds?) -> [GatedAudio] {
        let timeline = gate.clock.timeline
        guard let hostTime else {
            return processWithoutHostTime(input, timeline: timeline)
        }

        let start = Int64(clamping: hostTime.nanoseconds)
        let inputRate = input.format.sampleRate
        let frameCount = Int(input.frameLength)
        let held = heldFrames(inputRate: inputRate)
        let heldEnd = previousEndNanos ?? start
        previousEndNanos = Self.nanos(start, plusFrames: Double(frameCount), sampleRate: inputRate)

        let keptInput = timeline.keptRanges(startNanos: start, frameCount: frameCount, sampleRate: inputRate)
        guard let output = convert(converter == nil ? input : silencing(input, outside: keptInput)) else {
            return []
        }

        // A recording without pauses is stamped with the capture time as delivered.
        if timeline.admitsEverything {
            return [GatedAudio(buffer: output, hostTime: hostTime, rawHostTime: hostTime)]
        }

        let outputCount = Int(output.frameLength)
        let sampleRate = output.format.sampleRate
        let heldCount = min(Int((held - 1e-6).rounded(.up)), outputCount)
        let heldStart = Self.nanos(heldEnd, plusFrames: -held, sampleRate: sampleRate)
        let heldRanges = timeline.keptRanges(startNanos: heldStart, frameCount: heldCount, sampleRate: sampleRate)
        let mainRanges = timeline.keptRanges(
            startNanos: Self.nanos(start, plusFrames: Double(heldCount) - held, sampleRate: sampleRate),
            frameCount: outputCount - heldCount,
            sampleRate: sampleRate
        ).map {
            RecordingPauseTimeline.KeptRange(
                frames: ($0.frames.lowerBound + heldCount)..<($0.frames.upperBound + heldCount),
                removedNanos: $0.removedNanos
            )
        }

        var result: [GatedAudio] = []
        var mainPieces = mainRanges[...]
        for piece in heldRanges {
            if piece.frames.upperBound == heldCount, let next = mainPieces.first,
               next.frames.lowerBound == heldCount, next.removedNanos == piece.removedNanos {
                mainPieces = mainPieces.dropFirst()
                append(
                    piece.frames.lowerBound..<next.frames.upperBound,
                    removedNanos: piece.removedNanos, of: output, bufferStart: start, to: &result
                )
            } else {
                append(piece.frames, removedNanos: piece.removedNanos, of: output, bufferStart: heldEnd, to: &result)
            }
        }
        for piece in mainPieces {
            append(piece.frames, removedNanos: piece.removedNanos, of: output, bufferStart: start, to: &result)
        }
        return result
    }

    /// A buffer without a host time can't be tied to a pause, so once there has been one its audio
    /// must not stay in the converter. It still counts as an arriving buffer outside a pause.
    private func processWithoutHostTime(
        _ input: AVAudioPCMBuffer,
        timeline: RecordingPauseTimeline
    ) -> [GatedAudio] {
        previousEndNanos = nil
        let mustSilence = timeline.hasPauses && converter != nil
        guard let output = convert(mustSilence ? silencing(input, outside: []) : input), !timeline.isPaused else {
            return []
        }
        return [GatedAudio(buffer: mustSilence ? input : output, hostTime: nil, rawHostTime: nil)]
    }

    private func append(
        _ frames: Range<Int>,
        removedNanos: UInt64,
        of output: AVAudioPCMBuffer,
        bufferStart: Int64,
        to result: inout [GatedAudio]
    ) {
        guard let buffer = Self.slice(output, frames: frames) else { return }
        let raw = HostNanoseconds(
            startNanos: bufferStart, frame: frames.lowerBound, sampleRate: output.format.sampleRate
        )
        result.append(GatedAudio(buffer: buffer, hostTime: raw.removing(removedNanos), rawHostTime: raw))
    }

    /// Output frames the converter has taken in and not yet given out.
    private func heldFrames(inputRate: Double) -> Double {
        guard converter != nil, inputRate > 0 else { return 0 }
        return max(0, Double(inputFrames) * targetFormat.sampleRate / inputRate - Double(outputFrames))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer.frameLength > 0 ? buffer : nil }
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
            inputFrames += Int64(buffer.frameLength)
            outputFrames += Int64(output.frameLength)
            return output.frameLength > 0 ? output : nil
        default:
            return nil
        }
    }

    /// The buffer with everything outside `kept` set to silence, so that the converter's filter
    /// can't carry paused audio into the kept frames beside it. The frame count is unchanged. The
    /// capture framework's own buffer is not modified.
    private func silencing(
        _ buffer: AVAudioPCMBuffer,
        outside kept: [RecordingPauseTimeline.KeptRange]
    ) -> AVAudioPCMBuffer {
        let frameCount = Int(buffer.frameLength)
        if kept.reduce(0, { $0 + $1.frames.count }) == frameCount { return buffer }

        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: 0) ?? buffer
        }
        copy.frameLength = buffer.frameLength
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let sources = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let targets = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, target) in zip(sources, targets) {
            guard let sourceData = source.mData, let targetData = target.mData else { continue }
            memset(targetData, 0, Int(target.mDataByteSize))
            for range in kept {
                let offset = range.frames.lowerBound * bytesPerFrame
                memcpy(targetData + offset, sourceData + offset, range.frames.count * bytesPerFrame)
            }
        }
        return copy
    }

    private static func slice(_ buffer: AVAudioPCMBuffer, frames: Range<Int>) -> AVAudioPCMBuffer? {
        if frames == 0..<Int(buffer.frameLength) { return buffer }
        guard !frames.isEmpty,
              let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(frames.count)),
              let target = copy.floatChannelData
        else {
            return nil
        }
        copy.frameLength = AVAudioFrameCount(frames.count)
        for channel in 0..<Int(buffer.format.channelCount) {
            for index in 0..<frames.count {
                target[channel][index * copy.stride] = source[channel][(frames.lowerBound + index) * buffer.stride]
            }
        }
        return copy
    }

    private static func nanos(_ start: Int64, plusFrames frames: Double, sampleRate: Double) -> Int64 {
        start + Int64((frames * 1_000_000_000 / sampleRate).rounded())
    }
}

private extension HostNanoseconds {
    /// Time of `frame` in a buffer that starts at `startNanos`.
    init(startNanos: Int64, frame: Int, sampleRate: Double) {
        let offset = Int64((Double(frame) * 1_000_000_000 / sampleRate).rounded())
        self.init(nanoseconds: UInt64(clamping: startNanos + offset))
    }

    func removing(_ nanos: UInt64) -> HostNanoseconds {
        HostNanoseconds(nanoseconds: nanoseconds >= nanos ? nanoseconds - nanos : 0)
    }
}
