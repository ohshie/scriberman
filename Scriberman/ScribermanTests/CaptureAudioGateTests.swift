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
        let path: Path
        private let audio = AsyncStream<LiveAudioChunk>.makeStream()
        private let feed: (_ values: [Float], _ sampleRate: Double, _ hostTime: HostNanoseconds?) throws -> Void
        private let anchorBox = AnchorBox()
        private let received = ChunkBox()
        private var collector: Task<Void, Never>?
        private let retained: [AnyObject]

        final class AnchorBox: @unchecked Sendable {
            private let lock = NSLock()
            private var times: [HostNanoseconds] = []
            func add(_ time: HostNanoseconds) { lock.withLock { times.append(time) } }
            var first: HostNanoseconds? { lock.withLock { times.first } }
        }

        /// Everything the source sent to live transcription, markers included, in order.
        final class ChunkBox: @unchecked Sendable {
            private let lock = NSLock()
            private var chunks: [LiveAudioChunk] = []
            func add(_ chunk: LiveAudioChunk) { lock.withLock { chunks.append(chunk) } }
            var all: [LiveAudioChunk] { lock.withLock { chunks } }
        }

        init(_ path: Path, sampleRate: Double = 48_000) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            url = root.appendingPathComponent("audio.wav")
            self.sampleRate = sampleRate
            self.path = path
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
                    onBuffer: { output in
                        switch output {
                        case let .audio(samples, rate, adjusted, raw):
                            continuation.yield(LiveAudioChunk(
                                samples: samples, source: .mic, sampleRate: rate, hostTime: adjusted, rawHostTime: raw
                            ))
                        case let .pauseMarker(number):
                            continuation.yield(.pauseMarker(number, source: .mic))
                        }
                    }
                )
                feed = { values, rate, time in
                    tap.process(try CaptureAudioGateTests.makePCM(values, sampleRate: rate), hostTime: time)
                }
                retained = [tap]
            }
            let stream = audio.stream
            let box = received
            collector = Task { for await chunk in stream { box.add(chunk) } }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// What reached live transcription so far, once `condition` holds or after a timeout.
        func events(until condition: ([LiveAudioChunk]) -> Bool) async -> [LiveAudioChunk] {
            let deadline = Date().addingTimeInterval(5)
            while !condition(received.all), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return received.all
        }

        /// The service's call at resume, replacement and stop.
        func sendStartedPauseMarkers() {
            let continuation = audio.continuation
            let source = path.source
            gate.sendStartedPauseMarkers { continuation.yield(.pauseMarker($0, source: source)) }
        }

        var anchor: HostNanoseconds? { anchorBox.first }

        /// Feeds a 20 ms buffer.
        func send(_ value: Float, at time: HostNanoseconds?) throws {
            try feed(Array(repeating: value, count: Int(sampleRate / 50)), sampleRate, time)
        }

        func send(_ values: [Float], at time: HostNanoseconds?) throws {
            try feed(values, sampleRate, time)
        }

        /// `chunks` is the audio sent to live transcription; `events` adds the pause markers.
        func finish() async throws -> (
            samples: [Float], segments: [AudioCaptureSegment], chunks: [LiveAudioChunk], events: [LiveAudioChunk]
        ) {
            streamer.close()
            audio.continuation.finish()
            await collector?.value
            let events = received.all
            let chunks = events.filter { $0.pauseNumber == nil }
            let sidecar = AudioFileStreamer.loadTimingSidecar(for: url)
            let samples = try CaptureAudioGateTests.readSamples(url)
            // The sidecar describes the frames the file has, whatever was cut.
            #expect((sidecar?.totalFrames ?? 0) == samples.count)
            return (samples, sidecar?.segments ?? [], chunks, events)
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

    @Test
    func aPauseMarkerIsNeverReportedAsDelayedAudio() {
        var reports: [Bool] = []
        var monitor = LiveAudioQueueMonitor { _, delayed, _ in reports.append(delayed) }
        // Sent at a resume ten minutes after the pause started.
        monitor.observe(.pauseMarker(1, source: .app), now: ms(605_000))
        monitor.finish()
        #expect(reports.isEmpty)
    }

    // MARK: - Pause markers

    /// Raw interval of each pause, in ms after `startMs`.
    struct PauseSpan {
        let start: UInt64
        let end: UInt64?
    }

    /// Every marker is numbered in order, is sent once, follows every kept sample captured before
    /// its pause and precedes every one captured after it.
    ///
    /// Frames a converter held are stamped with the next input buffer's time, up to 2 ms after
    /// their capture, so audio before a marker may end that much past the pause start.
    static func expectMarkers(
        _ events: [LiveAudioChunk],
        _ pauses: [PauseSpan],
        source: AudioSource? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let events = events.filter { source == nil || $0.source == source }
        let markers = events.compactMap(\.pauseNumber)
        #expect(markers == Array(1...pauses.count), sourceLocation: sourceLocation)
        for (index, event) in events.enumerated() {
            guard let number = event.pauseNumber, number <= pauses.count else { continue }
            let pause = pauses[number - 1]
            let startNanos = (startMs + pause.start) * 1_000_000
            for audio in events[..<index] where audio.pauseNumber == nil {
                let raw = audio.rawHostTime?.nanoseconds ?? 0
                let end = raw + UInt64(Double(audio.samples.count) / audio.sampleRate * 1_000_000_000)
                #expect(end <= startNanos + 2_000_000, "audio ending at \(end) precedes marker \(number)", sourceLocation: sourceLocation)
            }
            guard let pauseEnd = pause.end else { continue }
            for audio in events[(index + 1)...] where audio.pauseNumber == nil {
                let raw = audio.rawHostTime?.nanoseconds ?? 0
                #expect(raw + 1_000 >= (startMs + pauseEnd) * 1_000_000, "audio at \(raw) follows marker \(number)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test(arguments: Path.allCases)
    func aSourceMarksAPauseAfterItsLastPrePauseSampleWithoutWaitingForResume(path: Path) async throws {
        let rig = try Rig(path)
        let perBuffer = 960
        for index in 0..<15 {
            if index == 5 { rig.clock.pause { ms(Self.startMs + 107) } }
            let values = (0..<perBuffer).map { frame -> Float in
                Double(index) * 20 + Double(frame) / 48 < 107 - 1e-6 ? Self.before : Self.paused
            }
            try rig.send(values, at: ms(Self.startMs + UInt64(index) * 20))
        }
        let duringPause = await rig.events { $0.contains { $0.pauseNumber != nil } }
        let marker = try #require(duringPause.firstIndex { $0.pauseNumber == 1 })
        #expect(duringPause[..<marker].reduce(0) { $0 + $1.samples.count } == 5_136)
        #expect(duringPause[(marker + 1)...].isEmpty)

        rig.clock.resume { ms(Self.startMs + 307) }
        for index in 15..<20 {
            try rig.send(Self.after, at: ms(Self.startMs + UInt64(index) * 20))
        }
        let result = try await rig.finish()
        Self.expectMarkers(result.events, [PauseSpan(start: 107, end: 307)])
        #expect(result.chunks.allSatisfy { $0.pauseNumber == nil && !$0.samples.isEmpty })
    }

    /// A resampled microphone gives out the last frames before the pause from the first buffer
    /// after it. They come before the marker.
    @Test(arguments: [Path.unifiedMic, .engineMic], [44_100.0, 24_000, 16_000])
    func framesTheConverterHeldComeBeforeTheMarker(path: Path, rate: Double) async throws {
        let rig = try Rig(path, sampleRate: rate)
        for index in 0..<20 {
            if index == 5 { rig.clock.pause { ms(Self.startMs + 100) } }
            if index == 15 { rig.clock.resume { ms(Self.startMs + 300) } }
            try rig.send((5..<15).contains(index) ? Self.paused : Self.before, at: ms(Self.startMs + UInt64(index) * 20))
        }
        let result = try await rig.finish()
        let marker = try #require(result.events.firstIndex { $0.pauseNumber == 1 })
        #expect(result.events[..<marker].reduce(0) { $0 + $1.samples.count } == 4_800)
        Self.expectMarkers(result.events, [PauseSpan(start: 100, end: 300)])
    }

    @Test(arguments: Path.allCases)
    func repeatedPausesAreMarkedInOrderIncludingOneInsideABuffer(path: Path) async throws {
        let rig = try Rig(path)
        let pauses = [PauseSpan(start: 100, end: 140), PauseSpan(start: 205, end: 215), PauseSpan(start: 307, end: 353)]
        for index in 0..<25 {
            let bufferStart = UInt64(index) * 20
            for pause in pauses {
                if pause.start >= bufferStart, pause.start < bufferStart + 20 { rig.clock.pause { ms(Self.startMs + pause.start) } }
                if let end = pause.end, end >= bufferStart, end < bufferStart + 20 { rig.clock.resume { ms(Self.startMs + end) } }
            }
            try rig.send(Self.before, at: ms(Self.startMs + bufferStart))
        }
        let result = try await rig.finish()
        Self.expectMarkers(result.events, pauses)
    }

    @Test(arguments: Path.allCases)
    func lateCallbacksKeepTheMarkersInOrderAndASilentPauseIsMarkedOnRequest(path: Path) async throws {
        let rig = try Rig(path)
        let pauses = [100, 200, 300].map { PauseSpan(start: $0, end: $0 + 40) }
        for pause in pauses {
            rig.clock.pause { ms(Self.startMs + pause.start) }
            rig.clock.resume { ms(Self.startMs + pause.end!) }
        }
        try rig.send(Self.before, at: ms(Self.startMs + 80))
        try rig.send(Self.paused, at: ms(Self.startMs + 120))
        try rig.send(Self.after, at: ms(Self.startMs + 140))
        try rig.send(Self.paused, at: ms(Self.startMs + 220))
        try rig.send(Self.after, at: ms(Self.startMs + 240))
        // Nothing is delivered past the third pause, so the source marks it when asked.
        rig.sendStartedPauseMarkers()
        rig.sendStartedPauseMarkers()
        try rig.send(Self.after, at: ms(Self.startMs + 360))
        let result = try await rig.finish()
        Self.expectMarkers(result.events, pauses)
    }

    @Test(arguments: Path.allCases)
    func anOpenPauseIsMarkedOnRequestAndOnlyOnce(path: Path) async throws {
        let rig = try Rig(path)
        try rig.send(Self.before, at: ms(Self.startMs))
        rig.clock.pause { ms(Self.startMs + 20) }
        rig.sendStartedPauseMarkers()
        try rig.send(Self.paused, at: ms(Self.startMs + 20))
        rig.clock.close { ms(Self.startMs + 60) }
        rig.sendStartedPauseMarkers()
        let result = try await rig.finish()
        Self.expectMarkers(result.events, [PauseSpan(start: 20, end: nil)])
    }

    /// Mic and app each run on their own queue and mark the same pauses independently. Pauses are
    /// set while the queues still have buffers captured before them.
    @Test
    func twoQueuesEachMarkEveryPauseInOrder() async throws {
        let gates = RecordingCaptureGates()
        let audio = AsyncStream<LiveAudioChunk>.makeStream()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = MicStreamOutputHandler(liveAudioContinuation: audio.continuation, gate: gates.mic)
        mic.configureOutput(url: root.appendingPathComponent("mic.wav"))
        let app = AppAudioStreamOutputHandler(liveAudioContinuation: audio.continuation, gate: gates.app)
        app.configureOutput(url: root.appendingPathComponent("app.wav"))
        let micQueue = DispatchQueue(label: "test.mic")
        let appQueue = DispatchQueue(label: "test.app")
        let micBuffers = try (0..<40).map { try Self.makeSampleBuffer(
            Array(repeating: Self.before, count: 960), sampleRate: 48_000, hostTime: ms(Self.startMs + UInt64($0) * 20)
        ) }
        let appBuffers = try (0..<40).map { try Self.makeSampleBuffer(
            Array(repeating: Self.before, count: 960), sampleRate: 48_000, hostTime: ms(Self.startMs + UInt64($0) * 20)
        ) }
        let feed = SampleBuffers(mic: micBuffers, app: appBuffers)
        // Each boundary is set before the buffer it falls in is delivered, while the queues may
        // still hold earlier buffers.
        let pauses = [PauseSpan(start: 187, end: 260), PauseSpan(start: 400, end: 433), PauseSpan(start: 587, end: 640)]
        for index in 0..<40 {
            let now = UInt64(index) * 20
            for pause in pauses {
                if (now..<now + 20).contains(pause.start) { gates.clock.pause { ms(Self.startMs + pause.start) } }
                if let end = pause.end, (now..<now + 20).contains(end) { gates.clock.resume { ms(Self.startMs + end) } }
            }
            micQueue.async { mic.processSampleBufferForTesting(feed.mic[index]) }
            appQueue.async { app.processSampleBufferForTesting(feed.app[index]) }
            if index.isMultiple(of: 3) { try await Task.sleep(for: .milliseconds(1)) }
        }
        micQueue.sync {}
        appQueue.sync {}
        mic.closeOutput()
        app.closeOutput()
        audio.continuation.finish()
        var events: [LiveAudioChunk] = []
        for await event in audio.stream { events.append(event) }
        Self.expectMarkers(events, pauses, source: .mic)
        Self.expectMarkers(events, pauses, source: .app)
    }

    private struct SampleBuffers: @unchecked Sendable {
        let mic: [CMSampleBuffer]
        let app: [CMSampleBuffer]
    }

    /// A restart replaces the handler but keeps the source's gate: the replacement does not repeat
    /// a marker, and a late callback on the old handler sends none.
    @Test
    func aReplacedHandlerDoesNotRepeatOrReorderMarkers() async throws {
        let gate = CaptureAudioGate()
        let audio = AsyncStream<LiveAudioChunk>.makeStream()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mic.wav")
        let streamer = AudioFileStreamer(label: "mic")
        let original = MicStreamOutputHandler(liveAudioContinuation: audio.continuation, streamer: streamer, gate: gate)
        original.configureOutput(url: url)
        func buffer(_ value: Float, at time: UInt64) throws -> CMSampleBuffer {
            try Self.makeSampleBuffer(Array(repeating: value, count: 960), sampleRate: 48_000, hostTime: ms(Self.startMs + time))
        }

        original.processSampleBufferForTesting(try buffer(Self.before, at: 0))
        gate.clock.pause { ms(Self.startMs + 20) }
        original.processSampleBufferForTesting(try buffer(Self.paused, at: 20))
        let replacement = MicStreamOutputHandler(liveAudioContinuation: audio.continuation, streamer: streamer, gate: gate)
        replacement.adoptPreparedOutput(url: url)
        replacement.processSampleBufferForTesting(try buffer(Self.paused, at: 40))
        gate.clock.resume { ms(Self.startMs + 60) }
        replacement.processSampleBufferForTesting(try buffer(Self.after, at: 60))
        original.processSampleBufferForTesting(try buffer(Self.paused, at: 40))
        gate.clock.pause { ms(Self.startMs + 80) }
        replacement.processSampleBufferForTesting(try buffer(Self.paused, at: 80))
        gate.clock.resume { ms(Self.startMs + 100) }
        replacement.processSampleBufferForTesting(try buffer(Self.after, at: 100))
        streamer.close()
        audio.continuation.finish()
        var events: [LiveAudioChunk] = []
        for await event in audio.stream { events.append(event) }
        Self.expectMarkers(events, [PauseSpan(start: 20, end: 60), PauseSpan(start: 80, end: 100)])
    }
}
