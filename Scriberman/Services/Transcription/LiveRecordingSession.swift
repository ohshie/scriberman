import Foundation
import OSLog

struct LiveAudioChunk: Sendable {
    let samples: [Float]
    let source: AudioSource
    let sampleRate: Double
    let hostTime: HostNanoseconds?
}

/// The streams and their only consumers belong to one recording attempt.
@MainActor
final class LiveRecordingSession {
    let generation = UUID()
    let clock = LiveCaptureClock()
    let audio = AsyncStream<LiveAudioChunk>.makeStream(bufferingPolicy: .unbounded)
    let results = AsyncStream<TranscriptSegment>.makeStream(bufferingPolicy: .unbounded)
    var audioConsumer: Task<Void, Never>?
    var resultConsumer: Task<Void, Never>?
    private var drainTask: Task<[TranscriptSegment], Never>?

    /// User stop and capture-start failure can request teardown concurrently.
    /// Both wait for the same drain and flush.
    func drainTranscription(using service: any LiveTranscribing) async -> [TranscriptSegment] {
        if let drainTask { return await drainTask.value }
        let task = Task {
            await self.drainAudio()
            let segments = await service.stop()
            self.results.continuation.finish()
            await self.drainResults()
            return segments
        }
        drainTask = task
        return await task.value
    }

    func finish() {
        audio.continuation.finish()
        results.continuation.finish()
    }

    func drainAudio() async {
        await audioConsumer?.value
        audioConsumer = nil
    }

    func drainResults() async {
        await resultConsumer?.value
        resultConsumer = nil
    }

    deinit {
        audio.continuation.finish()
        results.continuation.finish()
    }
}

struct LiveAudioQueueMonitor {
    static let warningThresholdSeconds: Double = 10
    private var delayedSources: Set<AudioSource> = []
    private let report: (AudioSource, Bool, Double) -> Void

    init(report: @escaping (AudioSource, Bool, Double) -> Void = { source, delayed, seconds in
        let logger = Logger(subsystem: "Scriberman", category: "LiveAudioQueue")
        if delayed {
            logger.warning("Queued audio for \(source.rawValue, privacy: .public) exceeds 10 seconds: \(seconds, privacy: .public)s")
        } else {
            logger.info("Queued audio for \(source.rawValue, privacy: .public) recovered: \(seconds, privacy: .public)s")
        }
    }) {
        self.report = report
    }

    mutating func finish() {
        for source in delayedSources { report(source, false, 0) }
        delayedSources.removeAll()
    }

    mutating func observe(_ chunk: LiveAudioChunk, now: HostNanoseconds = HostNanoseconds(machTicks: mach_absolute_time())) {
        guard let hostTime = chunk.hostTime else { return }
        let seconds = max(0, now.seconds(since: hostTime))
        if seconds > Self.warningThresholdSeconds {
            if delayedSources.insert(chunk.source).inserted { report(chunk.source, true, seconds) }
        } else if delayedSources.remove(chunk.source) != nil {
            report(chunk.source, false, seconds)
        }
    }
}

/// Capture callbacks record the shared reference before yielding their audio.
/// The same first-buffer times are used by RecordingService's saved mixdown.
final class LiveCaptureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var first: HostNanoseconds?

    var anchor: HostNanoseconds? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }

    func observe(_ hostTime: HostNanoseconds) {
        lock.lock()
        defer { lock.unlock() }
        first = first.map { min($0, hostTime) } ?? hostTime
    }
}
