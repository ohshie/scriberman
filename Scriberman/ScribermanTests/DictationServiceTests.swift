import CoreAudio
import FluidAudio
import Foundation
import Testing
@testable import Scriberman

@MainActor
@Suite
struct DictationServiceTests {
    private func makeService(
        capture: MockDictationCapture,
        recording: MockRecordingService = MockRecordingService(),
        insertText: @escaping @MainActor (String) -> InsertionOutcome = { _ in .insertedDirectly }
    ) -> DictationService {
        DictationService(
            recordingService: recording,
            captureSession: capture,
            insertText: insertText
        )
    }

    @Test
    func quickTapReturnsToIdleAndStaysResponsive() async {
        let capture = MockDictationCapture()
        await capture.setStartDelay(50_000_000)
        let service = makeService(capture: capture)
        service.transcribeHookForTesting = { _ in "hello" }

        // Mirror AppState's wiring: keyDown and keyUp fire as independent tasks.
        let startTask = Task { await service.start(deviceID: nil) }
        let stopTask = Task { await service.stop() }
        await startTask.value
        await stopTask.value

        #expect(service.state == .idle)

        // The service must remain responsive: a second session runs fully.
        let texts = InsertedTextRecorder()
        await capture.setSamplesOnStop([[Float](repeating: 0.05, count: 8_000)])
        let service2 = makeService(capture: capture) { text in
            texts.record(text)
            return .insertedDirectly
        }
        service2.transcribeHookForTesting = { _ in "second session" }
        await service2.start(deviceID: nil)
        await service2.stop()

        #expect(texts.texts == ["second session"])
        #expect(await capture.startCallCount() == 2)
    }

    @Test
    func missingModelReportsNoModelOutcome() async {
        let capture = MockDictationCapture()
        await capture.setSamplesOnStop([[Float](repeating: 0.05, count: 8_000)])
        let service = makeService(capture: capture)

        await service.start(deviceID: nil)
        await service.stop()

        #expect(service.lastOutcome == .failed(.noModel))
        #expect(service.state == .idle)
    }

    @Test
    func shortBufferIsPaddedToTheASRMinimum() async {
        let capture = MockDictationCapture()
        await capture.setSamplesOnStop([[Float](repeating: 0.05, count: 1_000)])
        let service = makeService(capture: capture)

        let observedCounts = SampleCountRecorder()
        service.transcribeHookForTesting = { samples in
            observedCounts.record(samples.count)
            return "hi"
        }

        await service.start(deviceID: nil)
        await service.stop()

        #expect(observedCounts.counts == [DictationService.minimumSampleCount])
    }

    @Test
    func padToMinimumLeavesLongBuffersUntouched() {
        #expect(DictationService.padToMinimum([Float](repeating: 1, count: 1_000)).count == DictationService.minimumSampleCount)
        let long = [Float](repeating: 1, count: 10_000)
        #expect(DictationService.padToMinimum(long).count == 10_000)
    }

    @Test
    func sessionProgressesThroughStatesAndPublishesOutcome() async {
        let capture = MockDictationCapture()
        await capture.setSamplesOnStop([[Float](repeating: 0.05, count: 8_000)])

        let box = ServiceBox()
        let statesAtInsert = StateRecorder()
        let service = makeService(capture: capture) { _ in
            if let state = box.service?.state {
                statesAtInsert.record(state)
            }
            return .typedOut
        }
        box.service = service

        let statesAtTranscribe = StateRecorder()
        service.transcribeHookForTesting = { _ in
            await MainActor.run {
                if let state = box.service?.state {
                    statesAtTranscribe.record(state)
                }
            }
            return "state check"
        }

        await service.start(deviceID: nil)
        #expect(service.state == .listening)
        await service.stop()

        #expect(statesAtTranscribe.states == [.transcribing])
        #expect(statesAtInsert.states == [.inserting])
        #expect(service.lastOutcome == .typedOut)
        #expect(service.state == .idle)
    }

    @Test
    func emptyTranscriptIsAReportedFailure() async {
        let capture = MockDictationCapture()
        await capture.setSamplesOnStop([[Float](repeating: 0.05, count: 8_000)])
        let service = makeService(capture: capture)
        service.transcribeHookForTesting = { _ in nil }

        await service.start(deviceID: nil)
        await service.stop()

        #expect(service.lastOutcome == .failed(.emptyTranscript))
    }

    @Test
    func releaseBeforeFirstBufferIsTooShortNotCaptureFailure() async {
        let capture = MockDictationCapture()
        // No samplesOnStop: the stream finishes without ever yielding audio,
        // as happens when the hotkey is released within milliseconds.
        let service = makeService(capture: capture)
        service.transcribeHookForTesting = { _ in "should never run" }

        await service.start(deviceID: nil)
        await service.stop()

        #expect(service.lastOutcome == .failed(.tooShort))
        #expect(service.state == .idle)
    }

    @Test
    func dictationBlockedWhileRecordingIsActive() async {
        let capture = MockDictationCapture()
        let recording = MockRecordingService()
        recording.isRecordingOverride = true
        let service = makeService(capture: capture, recording: recording)

        await service.start(deviceID: nil)

        #expect(service.state == .idle)
        #expect(await capture.startCallCount() == 0)
    }

    @Test
    func captureFailureIsAReportedOutcome() async {
        let capture = MockDictationCapture()
        await capture.setStartError(DictationCaptureError.invalidFormat)
        let service = makeService(capture: capture)

        await service.start(deviceID: nil)

        #expect(service.lastOutcome == .failed(.captureFailed))
        #expect(service.state == .idle)
    }
}

// MARK: - Test doubles

private actor MockDictationCapture: DictationCapturing {
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    private var startCalls = 0
    private var startDelayNanoseconds: UInt64 = 0
    private var samplesOnStop: [[Float]] = []
    private var startError: Error?

    func setStartDelay(_ nanoseconds: UInt64) {
        startDelayNanoseconds = nanoseconds
    }

    func setSamplesOnStop(_ samples: [[Float]]) {
        samplesOnStop = samples
    }

    func setStartError(_ error: Error) {
        startError = error
    }

    func startCallCount() -> Int {
        startCalls
    }

    func start(deviceID: AudioDeviceID?) async throws -> AsyncThrowingStream<[Float], Error> {
        startCalls += 1
        if let startError {
            throw startError
        }
        if startDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: startDelayNanoseconds)
        }
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() {
        for chunk in samplesOnStop {
            continuation?.yield(chunk)
        }
        continuation?.finish()
        continuation = nil
    }

    /// Delivers audio during the hold, as the microphone does while the hotkey is down.
    func yield(_ samples: [Float]) {
        continuation?.yield(samples)
    }

    func setLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {}
}

@MainActor
private final class ServiceBox {
    weak var service: DictationService?
}

private final class InsertedTextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var texts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func record(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(text)
    }
}

private final class SampleCountRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    var counts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func record(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(count)
    }
}

private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DictationState] = []
    var states: [DictationState] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func record(_ state: DictationState) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(state)
    }
}

@MainActor
struct DictationConversionFailureTests {
    @Test
    func failedConverterReportsCaptureFailureAndInsertsNothing() async {
        let capture = FailingConversionCapture()
        let inserted = InsertedTextRecorder()
        let service = DictationService(recordingService: MockRecordingService(), captureSession: capture) { text in
            inserted.record(text)
            return .insertedDirectly
        }
        service.transcribeHookForTesting = { _ in "must not insert" }
        await service.start(deviceID: nil)
        await service.stop()
        #expect(service.lastOutcome == .failed(.captureFailed))
        #expect(service.state == .idle)
        #expect(inserted.texts.isEmpty)
    }
}

private actor FailingConversionCapture: DictationCapturing {
    private var pipeline: DictationAudioPipeline?
    func start(deviceID: AudioDeviceID?) async throws -> AsyncThrowingStream<[Float], Error> {
        let pipeline = DictationAudioPipeline(converter: FailingDictationConverter())
        self.pipeline = pipeline
        pipeline.append([1], generation: pipeline.generation)
        return pipeline.stream
    }
    func stop() async { await pipeline?.stop() }
    func setLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) async {}
}

private struct FailingDictationConverter: DictationAudioConverting {
    func convert(_ samples: [Float]) throws -> [Float] {
        throw AudioResamplerError.conversionFailed("Injected failure")
    }
    func finish() throws -> [Float] { [] }
}

@MainActor
struct DictationPrewarmTests {
    private let workspace = Workspace(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))

    @Test
    func pressDuringPrewarmWaitsForThatLoad() async throws {
        let loads = AsrLoadProbe()
        let service = DictationService(
            recordingService: MockRecordingService(),
            captureSession: MockDictationCapture(),
            loadAsr: loads.load
        )

        let prewarm = Task { await service.prewarm(workspace: workspace) }
        #expect(await loads.waitForLoads(1))
        #expect(service.state == .prewarming)

        let press = Task { await service.start(deviceID: nil) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.state == .prewarming)

        loads.release()
        await prewarm.value
        await press.value

        #expect(loads.count == 1)
        #expect(service.state == .listening)
        await service.stop()
    }

    @Test
    func concurrentPrewarmsShareOneLoad() async {
        let loads = AsrLoadProbe()
        let service = DictationService(
            recordingService: MockRecordingService(),
            captureSession: MockDictationCapture(),
            loadAsr: loads.load
        )

        let first = Task { await service.prewarm(workspace: workspace) }
        let second = Task { await service.prewarm(workspace: workspace) }
        #expect(await loads.waitForLoads(1))
        loads.release()
        await first.value
        await second.value
        await service.prewarm(workspace: workspace)

        #expect(loads.count == 1)
        #expect(service.state == .idle)
    }

    @Test
    func changingWorkspaceDropsLoadedModels() async {
        let loads = AsrLoadProbe()
        loads.release()
        let capture = MockDictationCapture()
        await capture.setSamplesOnStop([[Float](repeating: 0.05, count: 8_000)])
        let service = DictationService(recordingService: MockRecordingService(), captureSession: capture, loadAsr: loads.load)
        await service.prewarm(workspace: workspace)
        let other = Workspace(rootURL: workspace.rootURL.appendingPathComponent("other"))
        service.prepare(for: other)
        await service.start(deviceID: nil)
        await service.stop()
        #expect(service.lastOutcome == .failed(.noModel))
        await service.prewarm(workspace: other)
        #expect(loads.count == 2)
    }

    @Test
    func cancelledWorkspaceLoadCannotRestoreOldModels() async {
        let loads = AsrLoadProbe()
        let capture = MockDictationCapture()
        await capture.setSamplesOnStop([[Float](repeating: 0.05, count: 8_000)])
        let service = DictationService(recordingService: MockRecordingService(), captureSession: capture, loadAsr: loads.load)
        let oldLoad = Task { await service.prewarm(workspace: workspace) }
        #expect(await loads.waitForLoads(1))
        service.prepare(for: Workspace(rootURL: workspace.rootURL.appendingPathComponent("other")))
        loads.release()
        await oldLoad.value
        await service.start(deviceID: nil)
        await service.stop()
        #expect(service.lastOutcome == .failed(.noModel))
        #expect(service.state == .idle)
    }

    @Test
    func failedPrewarmIsRetried() async {
        let loads = AsrLoadProbe(failures: 1)
        loads.release()
        let service = DictationService(
            recordingService: MockRecordingService(),
            captureSession: MockDictationCapture(),
            loadAsr: loads.load
        )

        await service.prewarm(workspace: workspace)
        await service.prewarm(workspace: workspace)

        #expect(loads.count == 2)
        #expect(service.state == .idle)
    }
}

/// Counts ASR loads; each load waits until `release()` and the first
/// `failures` loads throw.
private final class AsrLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0
    private var failures: Int
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(failures: Int = 0) {
        self.failures = failures
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    func release() {
        lock.lock()
        released = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func waitForLoads(_ expected: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while count < expected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return count >= expected
    }

    var load: @Sendable (Workspace) async throws -> AsrManager {
        { _ in
            let shouldFail = self.begin()
            await withCheckedContinuation { continuation in
                self.lock.lock()
                if self.released {
                    self.lock.unlock()
                    continuation.resume()
                } else {
                    self.waiters.append(continuation)
                    self.lock.unlock()
                }
            }
            if shouldFail { throw AsrLoadProbeError.failed }
            return AsrManager(config: ASRConfig())
        }
    }

    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loads += 1
        guard failures > 0 else { return false }
        failures -= 1
        return true
    }
}

private enum AsrLoadProbeError: Error {
    case failed
}

@MainActor
struct ProgressiveDictationServiceTests {
    private let second = [Float](repeating: 0.05, count: 16_000)

    private func makeService(
        capture: MockDictationCapture,
        mode: DictationModeBox = DictationModeBox(.progressive),
        canTypeDuringHold: Bool = true,
        insertText: @escaping @MainActor (String) -> InsertionOutcome
    ) -> DictationService {
        DictationService(
            recordingService: MockRecordingService(),
            captureSession: capture,
            insertText: insertText,
            mode: { mode.mode },
            canTypeDuringHold: { canTypeDuringHold }
        )
    }

    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> WordTiming {
        WordTiming(word: text, startTime: start, endTime: end)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test
    func modeChangeDuringPressDoesNotAffectThatPress() async {
        let capture = MockDictationCapture()
        await capture.setSamplesOnStop([second])
        let mode = DictationModeBox(.progressive)
        let passes = SampleCountRecorder()
        let inserted = InsertedTextRecorder()
        let service = makeService(capture: capture, mode: mode) { text in
            inserted.record(text)
            return .typedOut
        }
        service.progressivePassHookForTesting = { samples in
            passes.record(samples.count)
            return [WordTiming(word: "progressive", startTime: 0.1, endTime: 0.5)]
        }
        service.transcribeHookForTesting = { _ in "release-time" }

        await service.start(deviceID: nil)
        mode.mode = .releaseTime
        await service.stop()

        #expect(inserted.texts == ["progressive"])
        #expect(!passes.counts.isEmpty)
    }

    @Test
    func passesRunOnEachSecondOfNewAudio() async {
        let capture = MockDictationCapture()
        let passes = SampleCountRecorder()
        let service = makeService(capture: capture) { _ in .typedOut }
        service.progressivePassHookForTesting = { samples in
            passes.record(samples.count)
            return []
        }

        await service.start(deviceID: nil)
        await capture.yield(second)
        #expect(await waitUntil { passes.counts.count == 1 })
        await capture.yield([Float](repeating: 0.05, count: 8_000))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(passes.counts == [16_000])
        await capture.yield([Float](repeating: 0.05, count: 8_000))
        #expect(await waitUntil { passes.counts.count == 2 })
        await service.stop()

        // Two passes during the hold on the whole press (nothing committed), then the final pass.
        #expect(passes.counts == [16_000, 32_000, 32_000])
    }

    @Test
    func committedWordsAreTypedDuringTheHoldAndTheTailAtRelease() async {
        let capture = MockDictationCapture()
        let inserted = InsertedTextRecorder()
        let service = makeService(capture: capture) { text in
            inserted.record(text)
            return .typedOut
        }
        let script = PassScript([
            [word("Hello", 0.1, 0.4), word("my", 0.5, 0.8)],
            [word("Hello", 0.1, 0.4), word("my", 0.5, 0.8), word("name", 1.1, 1.5)],
            [word("Hello", 0.1, 0.4), word("my", 0.5, 0.8), word("name", 1.1, 1.5), word("is", 1.6, 1.9)],
        ])
        service.progressivePassHookForTesting = { _ in script.next() }

        await service.start(deviceID: nil)
        await capture.yield(second)
        await capture.yield(second)
        #expect(await waitUntil { inserted.texts.count == 1 })
        #expect(inserted.texts == ["Hello my"])
        await service.stop()

        #expect(inserted.texts == ["Hello my", " name is"])
        #expect(service.lastOutcome == .typedOut)
        #expect(service.state == .idle)
    }

    @Test
    func shortPressInsertsTheWholeTranscriptOnceAtRelease() async {
        let capture = MockDictationCapture()
        await capture.setSamplesOnStop([[Float](repeating: 0.05, count: 8_000)])
        let inserted = InsertedTextRecorder()
        let service = makeService(capture: capture) { text in
            inserted.record(text)
            return .insertedDirectly
        }
        service.progressivePassHookForTesting = { _ in
            [WordTiming(word: "Quick", startTime: 0.05, endTime: 0.2), WordTiming(word: "note.", startTime: 0.25, endTime: 0.45)]
        }

        await service.start(deviceID: nil)
        await service.stop()

        #expect(inserted.texts == ["Quick note."])
        #expect(service.lastOutcome == .inserted)
    }

    @Test
    func withoutAccessibilityThePressRunsReleaseTime() async {
        let capture = MockDictationCapture()
        await capture.setSamplesOnStop([second, second])
        let inserted = InsertedTextRecorder()
        let passes = SampleCountRecorder()
        let service = makeService(capture: capture, canTypeDuringHold: false) { text in
            inserted.record(text)
            return .copiedToClipboard
        }
        service.progressivePassHookForTesting = { samples in
            passes.record(samples.count)
            return nil
        }
        service.transcribeHookForTesting = { _ in "whole press" }

        await service.start(deviceID: nil)
        await service.stop()

        #expect(passes.counts.isEmpty)
        #expect(inserted.texts == ["whole press"])
        #expect(service.lastOutcome == .copiedToClipboard)
    }

    @Test
    func failedInsertionDuringTheHoldStopsThePress() async {
        let capture = MockDictationCapture()
        let inserted = InsertedTextRecorder()
        let service = makeService(capture: capture) { text in
            inserted.record(text)
            return .failed
        }
        let script = PassScript([
            [word("Hello", 0.1, 0.4), word("my", 0.5, 0.8)],
            [word("Hello", 0.1, 0.4), word("my", 0.5, 0.8), word("name", 1.1, 1.5)],
            [word("Hello", 0.1, 0.4), word("my", 0.5, 0.8), word("name", 1.1, 1.5), word("is", 1.6, 1.9)],
        ])
        service.progressivePassHookForTesting = { _ in script.next() }

        await service.start(deviceID: nil)
        await capture.yield(second)
        await capture.yield(second)
        #expect(await waitUntil { inserted.texts.count == 1 })
        await capture.yield(second)
        await service.stop()

        #expect(inserted.texts == ["Hello my"])
        #expect(script.calls == 2)
        #expect(service.lastOutcome == .failed(.insertionFailed))
        #expect(service.state == .idle)
    }

    @Test
    func conversionFailureEndsThePressWithoutInserting() async {
        let inserted = InsertedTextRecorder()
        let service = DictationService(
            recordingService: MockRecordingService(),
            captureSession: FailingConversionCapture(),
            insertText: { text in
                inserted.record(text)
                return .typedOut
            },
            mode: { .progressive },
            canTypeDuringHold: { true }
        )
        service.progressivePassHookForTesting = { _ in [WordTiming(word: "no", startTime: 0, endTime: 0.1)] }

        await service.start(deviceID: nil)
        await service.stop()

        #expect(service.lastOutcome == .failed(.captureFailed))
        #expect(service.state == .idle)
        #expect(inserted.texts.isEmpty)
    }
}

@MainActor
private final class DictationModeBox {
    var mode: DictationMode
    init(_ mode: DictationMode) { self.mode = mode }
}

/// Returns scripted pass results in order; the last one repeats.
private final class PassScript: @unchecked Sendable {
    private let lock = NSLock()
    private let passes: [[WordTiming]]
    private var index = 0

    init(_ passes: [[WordTiming]]) {
        self.passes = passes
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    func next() -> [WordTiming] {
        lock.lock()
        defer { lock.unlock() }
        let pass = passes[min(index, passes.count - 1)]
        index += 1
        return pass
    }
}
