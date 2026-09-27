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
