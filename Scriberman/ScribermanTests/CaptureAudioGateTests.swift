import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Scriberman

/// Pauses cut every capture path at the exact sample, before the file and live transcription.
///
/// Every buffer holds one constant value, so a sample's value says when it was captured.
struct CaptureAudioGateTests {
    static let before: Float = 0.25
    static let paused: Float = 0.9
    static let after: Float = -0.25
    private static let startMs: UInt64 = 10_000

    enum Path: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case unifiedMic, unifiedApp, engineMic, legacyApp
        var testDescription: String { rawValue }
        var source: AudioSource { self == .unifiedMic || self == .engineMic ? .mic : .app }
    }

    private static func ms(_ value: UInt64) -> HostNanoseconds {
        HostNanoseconds(nanoseconds: value * 1_000_000)
    }

    private func ms(_ value: UInt64) -> HostNanoseconds { Self.ms(value) }

    static func makePCM(_ values: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)))
        buffer.frameLength = AVAudioFrameCount(values.count)
        let data = try #require(buffer.floatChannelData)[0]
        for (index, value) in values.enumerated() { data[index] = value }
        return buffer
    }

    static func makeSampleBuffer(
        _ values: [Float],
        sampleRate: Double,
        hostTime: HostNanoseconds?
    ) throws -> CMSampleBuffer {
        let pcm = try makePCM(values, sampleRate: sampleRate)
        let description = pcm.format.formatDescription
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: hostTime.map {
                CMTime(value: CMTimeValue($0.nanoseconds), timescale: CMTimeScale(NSEC_PER_SEC))
            } ?? .invalid,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        #expect(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
            sampleCount: values.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
        ) == noErr)
        let buffer = try #require(sampleBuffer)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList
        ) == noErr)
        return buffer
    }

    /// One capture path writing to a real file, fed without hardware.
    private final class Rig {
        let clock = RecordingPauseClock()
        let gate: CaptureAudioGate
        let streamer: AudioFileStreamer
        let url: URL
        let root: URL
        let sampleRate: Double
        private let audio = AsyncStream<LiveAudioChunk>.makeStream()
        private let feed: (_ values: [Float], _ sampleRate: Double, _ hostTime: HostNanoseconds?) throws -> Void
        private let anchorBox = AnchorBox()
        private let retained: [AnyObject]

        final class AnchorBox: @unchecked Sendable {
            private let lock = NSLock()
            private var times: [HostNanoseconds] = []
            func add(_ time: HostNanoseconds) { lock.withLock { times.append(time) } }
            var first: HostNanoseconds? { lock.withLock { times.first } }
        }

        init(_ path: Path, sampleRate: Double = 48_000) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            url = root.appendingPathComponent("audio.wav")
            self.sampleRate = sampleRate
            let gate = CaptureAudioGate(clock: clock)
            self.gate = gate
            let streamer = AudioFileStreamer(label: path.rawValue)
            self.streamer = streamer
            let anchors = anchorBox
            switch path {
            case .unifiedMic:
                let handler = MicStreamOutputHandler(
                    liveAudioContinuation: audio.continuation, streamer: streamer, gate: gate
                )
                handler.configureOutput(url: url)
                handler.onFirstBufferHostTime = { anchors.add($0) }
                feed = { values, rate, time in
                    handler.processSampleBufferForTesting(
                        try CaptureAudioGateTests.makeSampleBuffer(values, sampleRate: rate, hostTime: time)
                    )
                }
                retained = [handler]
            case .unifiedApp:
                let handler = AppAudioStreamOutputHandler(
                    liveAudioContinuation: audio.continuation, streamer: streamer, gate: gate
                )
                handler.configureOutput(url: url)
                handler.onFirstBufferHostTime = { anchors.add($0) }
                feed = { values, rate, time in
                    handler.processSampleBufferForTesting(
                        try CaptureAudioGateTests.makeSampleBuffer(values, sampleRate: rate, hostTime: time)
                    )
                }
                retained = [handler]
            case .legacyApp:
                let session = AppAudioCaptureSession(
                    fileURL: url, processID: 1, onFirstBufferHostTime: { anchors.add($0) },
                    liveAudioContinuation: audio.continuation, streamer: streamer, gate: gate
                )
                session.outputHandler.configureOutput(url: url)
                feed = { values, rate, time in
                    session.outputHandler.processSampleBufferForTesting(
                        try CaptureAudioGateTests.makeSampleBuffer(values, sampleRate: rate, hostTime: time)
                    )
                }
                retained = [session]
            case .engineMic:
                let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
                try streamer.prepare(url: url, format: target)
                let continuation = audio.continuation
                let tap = try EngineMicTap(
                    inputFormat: try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)),
                    targetFormat: target,
                    micStreamer: streamer,
                    gate: gate,
                    onFirstHostTime: { anchors.add($0) },
                    onBuffer: { samples, rate, adjusted, raw in
                        continuation.yield(LiveAudioChunk(
                            samples: samples, source: .mic, sampleRate: rate, hostTime: adjusted, rawHostTime: raw
                        ))
                    }
                )
                feed = { values, rate, time in
                    tap.process(try CaptureAudioGateTests.makePCM(values, sampleRate: rate), hostTime: time)
                }
                retained = [tap]
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var anchor: HostNanoseconds? { anchorBox.first }

        /// Feeds a 20 ms buffer.
        func send(_ value: Float, at time: HostNanoseconds?) throws {
            try feed(Array(repeating: value, count: Int(sampleRate / 50)), sampleRate, time)
        }

        func send(_ values: [Float], at time: HostNanoseconds?) throws {
            try feed(values, sampleRate, time)
        }

        func finish() async throws -> (samples: [Float], segments: [AudioCaptureSegment], chunks: [LiveAudioChunk]) {
            streamer.close()
            audio.continuation.finish()
            var chunks: [LiveAudioChunk] = []
            for await chunk in audio.stream { chunks.append(chunk) }
            let sidecar = AudioFileStreamer.loadTimingSidecar(for: url)
            let samples = try CaptureAudioGateTests.readSamples(url)
            // The sidecar describes the frames the file has, whatever was cut.
            #expect((sidecar?.totalFrames ?? 0) == samples.count)
            return (samples, sidecar?.segments ?? [], chunks)
        }
    }

    static func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        var samples: [Float] = []
        // One read can return fewer frames than the buffer holds.
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            samples += UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength))
        }
        return samples
    }

    /// 100 ms before, 200 ms paused, 100 ms after, in 20 ms buffers. The values change at the
    /// boundaries, which lie 7 ms into a buffer.
    private func feedOnePause(_ rig: Rig, pauseMs: UInt64 = 107, resumeMs: UInt64 = 307) throws {
        let rate = rig.sampleRate
        let perBuffer = Int(rate / 50)
        for index in 0..<20 {
            if index == 5 { rig.clock.pause { ms(Self.startMs + pauseMs) } }
            if index == 15 { rig.clock.resume { ms(Self.startMs + resumeMs) } }
            let values = (0..<perBuffer).map { frame -> Float in
                let time = Double(index) * 20 + Double(frame) * 1_000 / rate
                if time < Double(pauseMs) - 1e-6 { return Self.before }
                return time < Double(resumeMs) - 1e-6 ? Self.paused : Self.after
            }
            try rig.send(values, at: ms(Self.startMs + UInt64(index) * 20))
        }
    }

    // MARK: - Boundaries

    @Test(arguments: Path.allCases)
    func bothBoundariesAreCutAtTheExactSample(path: Path) async throws {
        let rig = try Rig(path)
        try feedOnePause(rig)
        let result = try await rig.finish()

        let expected = [Float](repeating: Self.before, count: 5_136) + [Float](repeating: Self.after, count: 4_464)
        #expect(result.samples == expected)
        #expect(result.chunks.flatMap(\.samples) == expected)
        #expect(result.chunks.allSatisfy { $0.source == path.source })

        // The first kept sample after the pause was captured at 307 ms, which is 107 ms of recording.
        let cut = try #require(result.chunks.first { $0.samples.first == Self.after })
        #expect(cut.samples.count == 624)
        #expect(cut.hostTime == ms(Self.startMs + 107))
        #expect(cut.rawHostTime == ms(Self.startMs + 307))
        // Written segments are contiguous in adjusted time: nothing stands in for the pause.
        var expectedStart = Self.startMs * 1_000_000
        for segment in result.segments {
            #expect(segment.startHostTimeNanos == expectedStart)
            expectedStart += UInt64(segment.frameCount) * 1_000_000_000 / 48_000
        }
    }

    @Test(arguments: Path.allCases)
    func aPauseInsideOneBufferIsCutOut(path: Path) async throws {
        let rig = try Rig(path)
        rig.clock.pause { ms(Self.startMs + 5) }
        rig.clock.resume { ms(Self.startMs + 15) }
        try rig.send(
            [Float](repeating: Self.before, count: 240) + [Float](repeating: Self.paused, count: 480)
                + [Float](repeating: Self.after, count: 240),
            at: ms(Self.startMs)
        )
        let result = try await rig.finish()
        #expect(result.samples == [Float](repeating: Self.before, count: 240) + [Float](repeating: Self.after, count: 240))
        #expect(result.chunks.map(\.hostTime) == [ms(Self.startMs), ms(Self.startMs + 5)])
        #expect(result.chunks.map(\.rawHostTime) == [ms(Self.startMs), ms(Self.startMs + 15)])
    }

    @Test(arguments: Path.allCases)
    func lateBuffersAreCutAgainstThePausesTheyWereCapturedIn(path: Path) async throws {
        let rig = try Rig(path)
        for start: UInt64 in [100, 200, 300] {
            rig.clock.pause { ms(Self.startMs + start) }
            rig.clock.resume { ms(Self.startMs + start + 40) }
        }
        try rig.send(Self.before, at: ms(Self.startMs + 80))
        try rig.send(Self.paused, at: ms(Self.startMs + 120))
        try rig.send(Self.after, at: ms(Self.startMs + 140))
        try rig.send(Self.paused, at: ms(Self.startMs + 220))
        try rig.send(Self.after, at: ms(Self.startMs + 240))
        let result = try await rig.finish()
        #expect(!result.samples.contains(Self.paused))
        #expect(result.chunks.map(\.hostTime) == [ms(Self.startMs + 80), ms(Self.startMs + 100), ms(Self.startMs + 160)])
    }

    @Test(arguments: Path.allCases)
    func nothingCapturedAfterStopIsAdmitted(path: Path) async throws {
        let rig = try Rig(path)
        try rig.send(Self.before, at: ms(Self.startMs))
        rig.clock.close { ms(Self.startMs + 30) }
        try rig.send(
            [Float](repeating: Self.before, count: 480) + [Float](repeating: Self.paused, count: 480),
            at: ms(Self.startMs + 20)
        )
        try rig.send(Self.paused, at: ms(Self.startMs + 40))
        let result = try await rig.finish()
        #expect(result.samples == [Float](repeating: Self.before, count: 1_440))
        #expect(result.chunks.flatMap(\.samples) == result.samples)
    }

    @Test(arguments: Path.allCases)
    func stopWhilePausedAdmitsNeitherThePauseNorWhatFollows(path: Path) async throws {
        let rig = try Rig(path)
        try rig.send(Self.before, at: ms(Self.startMs))
        rig.clock.pause { ms(Self.startMs + 20) }
        try rig.send(Self.paused, at: ms(Self.startMs + 20))
        rig.clock.close { ms(Self.startMs + 50) }
        try rig.send(Self.paused, at: ms(Self.startMs + 40))
        try rig.send(Self.paused, at: ms(Self.startMs + 60))
        let result = try await rig.finish()
        #expect(result.samples == [Float](repeating: Self.before, count: 960))
        #expect(result.chunks.flatMap(\.samples) == result.samples)
    }

    // MARK: - Converter

    /// A 440 Hz tone outside the pause and full-scale alternating samples inside it: the kept
    /// output must not depend on what was captured during the pause.
    @Test(arguments: [Path.unifiedMic, .engineMic], [44_100.0, 24_000, 16_000, 96_000])
    func nothingCapturedDuringAPauseComesOutOfTheConverter(path: Path, rate: Double) async throws {
        func run(pausedLevel: Float) async throws -> [Float] {
            let rig = try Rig(path, sampleRate: rate)
            let perBuffer = Int(rate / 50)
            for index in 0..<20 {
                if index == 5 { rig.clock.pause { ms(Self.startMs + 107) } }
                if index == 15 { rig.clock.resume { ms(Self.startMs + 307) } }
                let values = (0..<perBuffer).map { frame -> Float in
                    let time = Double(index) * 20 + Double(frame) * 1_000 / rate
                    let isPaused = time >= 107 - 1e-6 && time < 307 - 1e-6
                    if isPaused { return frame.isMultiple(of: 2) ? pausedLevel : pausedLevel * 0.5 }
                    return 0.25 * sinf(Float(2 * Double.pi * 440 * time / 1_000))
                }
                try rig.send(values, at: ms(Self.startMs + UInt64(index) * 20))
            }
            let result = try await rig.finish()
            #expect(result.chunks.flatMap(\.samples) == result.samples)
            return result.samples
        }

        let silent = try await run(pausedLevel: 0)
        let loud = try await run(pausedLevel: 1)
        #expect(loud == silent)
        // 400 ms captured, 200 ms paused. The converter still holds its lookahead at the end.
        let held = 9_600 - silent.count
        #expect((0...100).contains(held))

        // Away from the filter's edges each sample is the tone at its own capture time.
        for index in silent.indices where !(5_136 - 200...5_136 + 200).contains(index) && index > 200 && index < silent.count - 200 {
            let time = Double(index) / 48_000 + (index < 5_136 ? 0 : 0.2)
            let expected = 0.25 * sinf(Float(2 * Double.pi * 440 * time))
            guard abs(silent[index] - expected) < 0.01 else {
                Issue.record("Sample \(index) is \(silent[index]), expected \(expected)")
                break
            }
        }
    }

    @Test(arguments: [Path.unifiedMic, .engineMic])
    func aPauseAddsNoGapToAConvertedSource(path: Path) async throws {
        let rig = try Rig(path, sampleRate: 44_100)
        try feedOnePause(rig)
        let result = try await rig.finish()
        let timeline = SynchronizedAudioTimeline.reconstruct(
            samples: result.samples, segments: result.segments,
            referenceHostTimeNanos: Self.startMs * 1_000_000, sampleRate: 48_000
        )
        // The one priming gap of an unpaused recording, and no trimmed audio.
        let unpaused = try Rig(path, sampleRate: 44_100)
        for index in 0..<10 { try unpaused.send(Self.before, at: ms(Self.startMs + UInt64(index) * 20)) }
        let reference = try await unpaused.finish()
        let baseline = SynchronizedAudioTimeline.reconstruct(
            samples: reference.samples, segments: reference.segments,
            referenceHostTimeNanos: Self.startMs * 1_000_000, sampleRate: 48_000
        )
        #expect(abs(timeline.insertedSilenceFrames - baseline.insertedSilenceFrames) <= 1)
        #expect(timeline.overlapFrames <= 1)
        #expect(abs(timeline.frames.count - baseline.frames.count) <= 1)
    }

    /// Frames the converter holds across a boundary belong to the side they were captured on. If
    /// they did not, frames captured during the pause would come out as silence after the cut.
    @Test(arguments: [Path.unifiedMic, .engineMic], [44_100.0, 24_000, 16_000])
    func heldFramesStayOnTheirSideOfTheCut(path: Path, rate: Double) async throws {
        let rig = try Rig(path, sampleRate: rate)
        for index in 0..<20 {
            if index == 5 { rig.clock.pause { ms(Self.startMs + 100) } }
            if index == 15 { rig.clock.resume { ms(Self.startMs + 300) } }
            try rig.send((5..<15).contains(index) ? Self.paused : Self.before, at: ms(Self.startMs + UInt64(index) * 20))
        }
        let result = try await rig.finish()
        // A step filtered symmetrically is near half its height on the boundary. Upsampling puts the
        // last kept input sample up to three output frames before it.
        let around = result.samples[4_500..<5_100]
        #expect(try #require(around.min()) > 0.05)
        #expect(try #require(around.max()) < 0.3)
        // Everything before the pause came out: 100 ms, on frame 4 800.
        let after = try #require(result.chunks.firstIndex { $0.rawHostTime.map { $0 >= ms(Self.startMs + 300) } ?? false })
        #expect(result.chunks[..<after].reduce(0) { $0 + $1.samples.count } == 4_800)
    }

    // MARK: - Timestamps

    @Test(arguments: Path.allCases)
    func buffersWithoutAHostTimeNeverReachLiveTranscription(path: Path) async throws {
        let rig = try Rig(path)
        try rig.send(Self.before, at: ms(Self.startMs))
        try rig.send(Self.paused, at: nil)
        rig.clock.pause { ms(Self.startMs + 40) }
        try rig.send(Self.paused, at: nil)
        rig.clock.resume { ms(Self.startMs + 60) }
        try rig.send(Self.paused, at: nil)
        try rig.send(Self.after, at: ms(Self.startMs + 60))
        // Outside a pause the buffer still counts; inside one it does not.
        #expect(rig.streamer.unplaceableBufferCount == 2)
        let result = try await rig.finish()
        #expect(result.chunks.map { $0.samples.first } == [Self.before, Self.after])
        #expect(!result.samples.contains(Self.paused))
    }

    @Test(arguments: [Path.unifiedMic, .engineMic])
    func audioOfATimestamplessBufferDoesNotSurviveInTheConverter(path: Path) async throws {
        func run(level: Float) async throws -> [Float] {
            let rig = try Rig(path, sampleRate: 44_100)
            try rig.send(Self.before, at: ms(Self.startMs))
            rig.clock.pause { ms(Self.startMs + 20) }
            rig.clock.resume { ms(Self.startMs + 40) }
            // Delivered after the resume, possibly captured during the pause.
            try rig.send(level, at: nil)
            try rig.send(Self.after, at: ms(Self.startMs + 40))
            return try await rig.finish().samples
        }
        #expect(try await run(level: Self.paused) == run(level: 0))
    }

    // MARK: - Anchors and accounting

    @Test(arguments: Path.allCases)
    func aFirstBufferInsideAPauseIsAnchoredByItsFirstKeptSample(path: Path) async throws {
        let rig = try Rig(path)
        rig.clock.pause { ms(Self.startMs) }
        try rig.send(Self.paused, at: ms(Self.startMs + 20))
        #expect(rig.anchor == nil)
        rig.clock.resume { ms(Self.startMs + 50) }
        try rig.send([Float](repeating: Self.paused, count: 480) + [Float](repeating: Self.after, count: 480), at: ms(Self.startMs + 40))
        #expect(rig.anchor == ms(Self.startMs))
        let result = try await rig.finish()
        #expect(result.samples == [Float](repeating: Self.after, count: 480))
        #expect(result.segments.first?.startHostTimeNanos == Self.startMs * 1_000_000)
    }

    @Test(arguments: Path.allCases)
    func discardedBuffersAreNotActivityAndEveryArrivalIsCounted(path: Path) async throws {
        let rig = try Rig(path)
        rig.clock.pause { ms(Self.startMs) }
        // Longer than the sustained run the activity tracker needs.
        let deadline = Date().addingTimeInterval(1.6)
        var time = Self.startMs
        var sent: Int64 = 0
        while Date() < deadline {
            try rig.send(Self.paused, at: sent.isMultiple(of: 2) ? ms(time) : nil)
            time += 20
            sent += 1
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(rig.streamer.lastActivityAt == nil)
        #expect(rig.gate.arrivalCount == sent)
        #expect(rig.streamer.framesWritten == 0)
    }

    @Test
    func timestamplessBuffersOutsideAPauseStillCountAsActivityAfterOne() async throws {
        let rig = try Rig(.unifiedMic, sampleRate: 44_100)
        rig.clock.pause { ms(Self.startMs) }
        rig.clock.resume { ms(Self.startMs + 20) }
        let deadline = Date().addingTimeInterval(20)
        while rig.streamer.lastActivityAt == nil, Date() < deadline {
            try rig.send(Self.after, at: nil)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.streamer.lastActivityAt != nil)
    }

    @Test
    func queueMonitorMeasuresDelayFromTheRawTime() {
        var reports: [Bool] = []
        var monitor = LiveAudioQueueMonitor { _, delayed, _ in reports.append(delayed) }
        // Captured one second ago, after a ten-minute pause.
        monitor.observe(
            LiveAudioChunk(samples: [1], source: .mic, sampleRate: 48_000, hostTime: ms(5_000), rawHostTime: ms(605_000)),
            now: ms(606_000)
        )
        #expect(reports.isEmpty)
    }
}
