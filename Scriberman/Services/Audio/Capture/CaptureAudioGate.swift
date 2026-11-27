@preconcurrency import AVFoundation
import Foundation
import OSLog

/// One source's view of the recording's pause clock. It belongs to the recording, so every handler
/// the source gets during that recording uses the same one.
///
/// It also numbers the source's pause markers. A marker tells live transcription that the source
/// has sent all its audio from before that pause. Each is sent once, in order, whichever handler or
/// caller sends it.
///
/// @unchecked Sendable: the counter and arrival time are guarded by `lock`, the marker count by
/// `deliveryLock`; `clock` synchronizes itself.
final class CaptureAudioGate: @unchecked Sendable {
    let clock: RecordingPauseClock
    private let hostNow: @Sendable () -> HostNanoseconds
    private let lock = NSLock()
    private var _arrivalCount: Int64 = 0
    private var _lastArrivalHostTime: HostNanoseconds?
    private var nextArrivalObserver: (@Sendable (HostNanoseconds) -> Void)?
    /// Held while a handler hands out a buffer's audio and markers, and while markers are sent on
    /// request, so a marker never lands between audio it must follow.
    private let deliveryLock = NSLock()
    /// Pauses whose marker has been sent.
    private var markedPauseCount = 0

    init(
        clock: RecordingPauseClock = RecordingPauseClock(),
        hostNow: @escaping @Sendable () -> HostNanoseconds = { HostNanoseconds(machTicks: mach_absolute_time()) }
    ) {
        self.clock = clock
        self.hostNow = hostNow
    }

    /// Raw buffers delivered by the capture framework, counted before anything is cut. Unlike
    /// `framesWritten` this advances during a pause.
    var arrivalCount: Int64 { lock.withLock { _arrivalCount } }

    /// When the last raw buffer was delivered, by the host clock. Nil before the first one.
    var lastArrivalHostTime: HostNanoseconds? { lock.withLock { _lastArrivalHostTime } }

    func recordArrival() {
        let now = hostNow()
        let observer = lock.withLock {
            _arrivalCount += 1
            _lastArrivalHostTime = now
            let observer = nextArrivalObserver
            nextArrivalObserver = nil
            return observer
        }
        observer?(now)
    }

    /// Calls `observer` once, with its arrival time, for the next raw buffer delivered. Replaces an
    /// observer that has not been called yet.
    func observeNextArrival(_ observer: @escaping @Sendable (HostNanoseconds) -> Void) {
        lock.withLock { nextArrivalObserver = observer }
    }

    /// Sends the marker of every pause that has started, up to pause number `limit`, and is not yet
    /// marked. Used when the source may not deliver another buffer past the pause: at resume, at a
    /// capture replacement and at stop.
    func sendStartedPauseMarkers(through limit: Int = .max, _ send: (Int) -> Void) {
        deliveryLock.withLock {
            let started = min(clock.timeline.pauseStarts.count, limit)
            while markedPauseCount < started {
                markedPauseCount += 1
                send(markedPauseCount)
            }
        }
    }

    /// Hands a buffer's kept audio to `send` in capture order, with the marker of each pause whose
    /// earlier audio has now all come out.
    ///
    /// A marker goes before the first piece captured after its pause. Otherwise it goes last, once
    /// `emittedThroughNanos` (the raw time up to which the source's audio has come out of its
    /// converter) has reached the pause. `timeline` is the snapshot the buffer was cut against.
    fileprivate func deliver(
        _ audio: [GatedAudio],
        emittedThroughNanos: Int64?,
        timeline: RecordingPauseTimeline,
        to send: (GatedAudioEvent) -> Void
    ) {
        deliveryLock.withLock {
            func mark(through number: Int) {
                while markedPauseCount < number {
                    markedPauseCount += 1
                    send(.pauseMarker(markedPauseCount))
                }
            }
            for piece in audio {
                if let pausesBefore = piece.pausesBefore { mark(through: pausesBefore) }
                send(.audio(piece))
            }
            if let emittedThroughNanos, emittedThroughNanos >= 0 {
                let started = timeline.pauseStarts.filter { $0 <= UInt64(emittedThroughNanos) }.count
                mark(through: started)
            }
        }
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

    init(
        clock: RecordingPauseClock = RecordingPauseClock(),
        hostNow: @escaping @Sendable () -> HostNanoseconds = { HostNanoseconds(machTicks: mach_absolute_time()) }
    ) {
        self.clock = clock
        self.mic = CaptureAudioGate(clock: clock, hostNow: hostNow)
        self.app = CaptureAudioGate(clock: clock, hostNow: hostNow)
    }
}

/// What a source hands to its file writer and to live transcription.
enum GatedAudioEvent {
    case audio(GatedAudio)
    /// All of the source's audio from before pause number `n` has been handed out.
    case pauseMarker(Int)
}

/// Audio that passed the gate.
struct GatedAudio {
    let buffer: AVAudioPCMBuffer
    /// Adjusted time of the first frame. Nil for a buffer that arrived without a host time, which
    /// the file writer counts and drops, and which must not reach live transcription.
    let hostTime: HostNanoseconds?
    let rawHostTime: HostNanoseconds?
    /// Pauses that ended before the first frame was captured. Nil without a host time. The raw time
    /// does not tell: frames a converter held are stamped with the next input buffer's time.
    var pausesBefore: Int?
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
    private var previousInputRate: Double?

    /// `converter` is nil for a source that already delivers `targetFormat`.
    init(converter: AVAudioConverter?, targetFormat: AVAudioFormat, gate: CaptureAudioGate) {
        self.converter = converter
        self.targetFormat = targetFormat
        self.gate = gate
    }

    /// Converts and cuts one buffer, then hands its kept audio and the source's due pause markers to
    /// `send`, in order.
    func process(_ input: AVAudioPCMBuffer, hostTime: HostNanoseconds?, send: (GatedAudioEvent) -> Void) {
        let timeline = gate.clock.timeline
        let audio: [GatedAudio]
        if let hostTime {
            audio = cut(input, hostTime: hostTime, timeline: timeline)
        } else {
            audio = processWithoutHostTime(input, timeline: timeline)
        }
        gate.deliver(audio, emittedThroughNanos: emittedThroughNanos, timeline: timeline, to: send)
    }

    /// Raw time up to which this source's audio has come out of the converter: the end of the last
    /// buffer, less what the converter still holds. Nil after a buffer without a host time.
    private var emittedThroughNanos: Int64? {
        guard let previousEndNanos, let previousInputRate else { return nil }
        return Self.nanos(previousEndNanos, plusFrames: -heldFrames(inputRate: previousInputRate), sampleRate: targetFormat.sampleRate)
    }

    private func cut(
        _ input: AVAudioPCMBuffer,
        hostTime: HostNanoseconds,
        timeline: RecordingPauseTimeline
    ) -> [GatedAudio] {

        let start = Int64(clamping: hostTime.nanoseconds)
        let inputRate = input.format.sampleRate
        let frameCount = Int(input.frameLength)
        let held = heldFrames(inputRate: inputRate)
        let heldEnd = previousEndNanos ?? start
        previousEndNanos = Self.nanos(start, plusFrames: Double(frameCount), sampleRate: inputRate)
        previousInputRate = inputRate

        let keptInput = timeline.keptRanges(startNanos: start, frameCount: frameCount, sampleRate: inputRate)
        guard let output = convert(converter == nil ? input : silencing(input, outside: keptInput)) else {
            return []
        }

        // A recording without pauses is stamped with the capture time as delivered.
        if timeline.admitsEverything {
            return [GatedAudio(buffer: output, hostTime: hostTime, rawHostTime: hostTime, pausesBefore: 0)]
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
                removedNanos: $0.removedNanos,
                pausesBefore: $0.pausesBefore
            )
        }

        var result: [GatedAudio] = []
        var mainPieces = mainRanges[...]
        for piece in heldRanges {
            if piece.frames.upperBound == heldCount, let next = mainPieces.first,
               next.frames.lowerBound == heldCount, next.removedNanos == piece.removedNanos,
               next.pausesBefore == piece.pausesBefore {
                mainPieces = mainPieces.dropFirst()
                append(
                    piece.frames.lowerBound..<next.frames.upperBound,
                    range: piece, of: output, bufferStart: start, to: &result
                )
            } else {
                append(piece.frames, range: piece, of: output, bufferStart: heldEnd, to: &result)
            }
        }
        for piece in mainPieces {
            append(piece.frames, range: piece, of: output, bufferStart: start, to: &result)
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
        range: RecordingPauseTimeline.KeptRange,
        of output: AVAudioPCMBuffer,
        bufferStart: Int64,
        to result: inout [GatedAudio]
    ) {
        guard let buffer = Self.slice(output, frames: frames) else { return }
        let raw = HostNanoseconds(
            startNanos: bufferStart, frame: frames.lowerBound, sampleRate: output.format.sampleRate
        )
        result.append(GatedAudio(
            buffer: buffer,
            hostTime: raw.removing(range.removedNanos),
            rawHostTime: raw,
            pausesBefore: range.pausesBefore
        ))
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


/// Capture instrumentation ported from mic-disconnect ticket 10. Every line carries the recording's trace id and the host clock in seconds
/// (`t=`, the clock buffer timestamps use), so latencies are computed from the log alone:
/// request, detection, operation start and end, first valid buffer after conversion, first
/// successful write, and the captured-mic state the recording view reads. The mic writer also
/// logs one level line per second of written audio, so zero-valued input shows in the log.
enum CaptureTrace {
    private static let logger = Logger(subsystem: "Scriberman", category: "CaptureTrace")

    private struct State {
        var id = "none"
        var counter = 0
        /// The target whose first converted buffer and first write are still to be logged.
        var awaitingConverted: String?
        var awaitingWrite: String?
        var windowStart: UInt64?
        var windowFrames = 0
        var windowPeak: Float = 0
        var windowSumSquares: Double = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func nowNanoseconds() -> UInt64 {
        HostNanoseconds(machTicks: mach_absolute_time()).nanoseconds
    }

    static func seconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000_000)
    }

    /// Starts a new trace id for a recording and logs the start request.
    static func beginRecording(_ detail: String) {
        let id: String = lock.withLock {
            state.counter += 1
            state.id = "R\(state.counter)-\(String(UInt16.random(in: 0...UInt16.max), radix: 16))"
            state.awaitingConverted = nil
            state.awaitingWrite = nil
            state.windowStart = nil
            return state.id
        }
        logger.notice("trace id=\(id, privacy: .public) t=\(seconds(nowNanoseconds()), privacy: .public) event=startRequested \(detail, privacy: .public)")
    }

    static func log(_ event: String, _ detail: String = "") {
        let id = lock.withLock { state.id }
        logger.notice("trace id=\(id, privacy: .public) t=\(seconds(nowNanoseconds()), privacy: .public) event=\(event, privacy: .public) \(detail, privacy: .public)")
    }

    /// Times one operation: logs `opBegin` now and returns a closure that logs `opEnd`.
    static func begin(_ operation: String, _ detail: String = "") -> @Sendable (String) -> Void {
        let started = nowNanoseconds()
        log("opBegin", "op=\(operation) \(detail)")
        return { result in
            let ms = Double(nowNanoseconds() - started) / 1_000_000
            log("opEnd", "op=\(operation) result=\(result) ms=\(String(format: "%.1f", ms)) \(detail)")
        }
    }

    /// Capture was aimed at `target`: its first converted buffer and first write are logged.
    static func armFirstBuffer(target: String) {
        lock.withLock {
            state.awaitingConverted = target
            state.awaitingWrite = target
        }
    }

    /// A buffer came out of conversion (48 kHz mono, not paused).
    static func noteConverted(_ buffer: AVAudioPCMBuffer, hostTime: HostNanoseconds?) {
        guard let target = lock.withLock({ () -> String? in
            defer { state.awaitingConverted = nil }
            return state.awaitingConverted
        }) else { return }
        let (peak, _) = levels(buffer)
        log("firstValidBuffer", "target=\(target) bufferT=\(hostTime.map { seconds($0.nanoseconds) } ?? "none") frames=\(buffer.frameLength) peak=\(String(format: "%.5f", peak))")
    }

    /// A mic buffer reached the file.
    static func noteMicWritten(_ buffer: AVAudioPCMBuffer, hostTimeNanos: UInt64) {
        let (peak, sumSquares) = levels(buffer)
        var firstWriteTarget: String?
        var window: (start: UInt64, frames: Int, peak: Float, rms: Double)?
        lock.withLock {
            firstWriteTarget = state.awaitingWrite
            state.awaitingWrite = nil
            if let start = state.windowStart,
               Double(hostTimeNanos) - Double(start) >= 1_000_000_000 || hostTimeNanos < start {
                let rms = state.windowFrames > 0 ? (state.windowSumSquares / Double(state.windowFrames)).squareRoot() : 0
                window = (start, state.windowFrames, state.windowPeak, rms)
                state.windowStart = nil
            }
            if state.windowStart == nil {
                state.windowStart = hostTimeNanos
                state.windowFrames = 0
                state.windowPeak = 0
                state.windowSumSquares = 0
            }
            state.windowFrames += Int(buffer.frameLength)
            state.windowPeak = max(state.windowPeak, peak)
            state.windowSumSquares += sumSquares
        }
        if let firstWriteTarget {
            log("firstWrite", "target=\(firstWriteTarget) bufferT=\(seconds(hostTimeNanos)) frames=\(buffer.frameLength) peak=\(String(format: "%.5f", peak))")
        }
        if let window {
            let db = window.rms > 0 ? 20 * log10(window.rms) : -200
            log("micSecond", "bufferT=\(seconds(window.start)) frames=\(window.frames) peak=\(String(format: "%.5f", window.peak)) rmsDb=\(String(format: "%.1f", db))")
        }
    }

    private static func levels(_ buffer: AVAudioPCMBuffer) -> (peak: Float, sumSquares: Double) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return (0, 0) }
        var peak: Float = 0
        var sum: Double = 0
        let samples = data[0]
        for index in 0..<Int(buffer.frameLength) {
            let value = samples[index]
            peak = max(peak, abs(value))
            sum += Double(value * value)
        }
        return (peak, sum)
    }
}
