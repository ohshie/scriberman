import Foundation
import ScreenCaptureKit

/// The subset of `SCStream` that `UnifiedCaptureSession` actually drives.
///
/// Exists so the session's lifecycle and mic-retarget logic can be exercised without a real
/// capture stream: constructing an `SCStream` requires live `SCShareableContent`, a capturable
/// window, and Screen Recording + Microphone TCC grants, none of which are available in tests.
protocol UnifiedCaptureStreaming: AnyObject {
    func addStreamOutput(
        _ output: SCStreamOutput,
        type: SCStreamOutputType,
        sampleHandlerQueue: DispatchQueue?
    ) throws
    func startCapture() async throws
    func stopCapture() async throws
    func updateConfiguration(_ configuration: SCStreamConfiguration) async throws
}

extension SCStream: UnifiedCaptureStreaming {}

/// An unstructured race, like ticket 09's ResumeOnce: a framework call can outlive its
/// deadline without keeping its caller (or the recording actor) suspended. Never use a task
/// group here: exiting one waits for a framework call that ignores cancellation.
enum BoundedCaptureCall {
    static let startLimit: Duration = .seconds(2)
    static let switchLimit: Duration = .seconds(1)
    static let stopLimit: Duration = .seconds(1)
    struct TimedOut: Error {}
    private static let deadlineQueue = DispatchQueue(label: "Scriberman.ScreenCaptureDeadlines", qos: .userInitiated)

    static func run<T: Sendable>(
        call: String, device: String?, until deadline: ContinuousClock.Instant,
        onAbandon: @escaping @Sendable () -> Void = {},
        lateResult: @escaping @Sendable (Result<T, any Error>) async -> Void = { _ in },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = Completion<T>()
        let began = ContinuousClock.now
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                guard !race.isFinished else { return }
                let expire: @Sendable () -> Void = {
                    race.finish(.failure(TimedOut())) {
                        CaptureTrace.log("streamCallTimeout", "call=\(call) device=\(device ?? "<default>") elapsed=\(ContinuousClock.now - began)")
                        onAbandon()
                    }
                }
                let timer = DispatchWorkItem(block: expire)
                let remaining = max(.zero, deadline - ContinuousClock.now).components
                let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                deadlineQueue.asyncAfter(deadline: .now() + seconds, execute: timer)
                Task.detached(executorPreference: CaptureCallExecutor()) {
                    let result: Result<T, any Error>
                    do { result = .success(try await operation()) } catch { result = .failure(error) }
                    if ContinuousClock.now >= deadline { expire() }
                    if !race.finish(result) { await lateResult(result) }
                    timer.cancel()
                }
            }
        } onCancel: {
            race.finish(.failure(CancellationError()), beforeResume: onAbandon)
        }
    }

    /// Cancellation can win before the continuation is installed. Store its result in that case.
    private final class Completion<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var result: Result<T, any Error>?
        var isFinished: Bool { lock.withLock { result != nil } }
        func install(_ continuation: CheckedContinuation<T, any Error>) {
            lock.withLock {
                if let result { continuation.resume(with: result) }
                else { self.continuation = continuation }
            }
        }
        @discardableResult
        func finish(_ result: Result<T, any Error>, beforeResume: () -> Void = {}) -> Bool {
            lock.withLock {
                guard self.result == nil else { return false }
                self.result = result
                beforeResume()
                continuation?.resume(with: result)
                continuation = nil
                return true
            }
        }
    }
}

/// The framework objects predate Swift Sendable. A call owns its reference even after timeout.
struct CaptureStreamReference: @unchecked Sendable {
    let stream: any UnifiedCaptureStreaming
}

/// A separate queue for every call: a synchronous framework hang cannot occupy the recording
/// actor or Swift's shared worker pool, or hold a later call behind it.
final class CaptureCallExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "Scriberman.ScreenCaptureCall.\(UUID().uuidString)")
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// Immutable for the lifetime of a call. Never hand a retained, mutable configuration to an
/// operation that can outlive its caller.
struct CaptureConfigurationReference: @unchecked Sendable {
    let configuration: SCStreamConfiguration
}
