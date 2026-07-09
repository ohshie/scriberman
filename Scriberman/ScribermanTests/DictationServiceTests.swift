import CoreAudio
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
    private var continuation: AsyncStream<[Float]>.Continuation?
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

    func start(deviceID: AudioDeviceID?) async throws -> AsyncStream<[Float]> {
        startCalls += 1
        if let startError {
            throw startError
        }
        if startDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: startDelayNanoseconds)
        }
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
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
