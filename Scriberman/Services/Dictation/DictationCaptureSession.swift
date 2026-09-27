import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Capture abstraction so `DictationService` state logic is unit-testable
/// without a live microphone.
protocol DictationCapturing: Sendable {
    func start(deviceID: AudioDeviceID?) async throws -> AsyncThrowingStream<[Float], Error>
    func stop() async
    func setLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) async
}

actor DictationCaptureSession: DictationCapturing {
    private let logger = Logger(subsystem: "Scriberman", category: "DictationCapture")
    private static let targetSampleRate: Double = 16_000

    // The engine is created and prepared once and retained across sessions so
    // capture starts within tens of milliseconds of keyDown (design D2). It is
    // rebuilt only when the input device changes.
    private var audioEngine: AVAudioEngine?
    private var configuredDeviceID: AudioDeviceID?
    private var pipeline: DictationAudioPipeline?
    private var levelHandler: (@Sendable (Float) -> Void)?

    func setLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {
        levelHandler = handler
    }

    // Starts the mic tap for the given device (nil = system default).
    // Returns mono 16 kHz samples; conversion errors terminate the stream.
    func start(deviceID: AudioDeviceID?) async throws -> AsyncThrowingStream<[Float], Error> {
        await endCapture()

        let normalizedDeviceID = (deviceID != nil && deviceID != 0) ? deviceID : nil
        let engine = try engineReady(for: normalizedDeviceID)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            teardownEngine()
            throw DictationCaptureError.invalidFormat
        }

        let converter = try ContinuousAudioResampler(sourceSampleRate: inputFormat.sampleRate, targetSampleRate: Self.targetSampleRate)
        let pipeline = DictationAudioPipeline(converter: converter)
        self.pipeline = pipeline
        let reportLevel = levelHandler

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
            let mono = AudioDownmixer.toMono(buffer: buffer)
            guard !mono.isEmpty else { return }
            if let reportLevel {
                var sumOfSquares: Float = 0
                for sample in mono {
                    sumOfSquares += sample * sample
                }
                reportLevel(sqrt(sumOfSquares / Float(mono.count)))
            }
            pipeline.append(mono, generation: pipeline.generation)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            await pipeline.stop()
            self.pipeline = nil
            teardownEngine()
            throw error
        }
        logger.info("Dictation capture started (device: \(normalizedDeviceID.map { String($0) } ?? "default"))")
        return pipeline.stream
    }

    func stop() async {
        await endCapture()
        logger.info("Dictation capture stopped (engine retained)")
    }

    // Stops the current tap/stream but retains the prepared engine for reuse.
    private func endCapture() async {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let current = pipeline
        pipeline = nil
        await current?.stop()
    }

    private func engineReady(for deviceID: AudioDeviceID?) throws -> AVAudioEngine {
        if let engine = audioEngine, configuredDeviceID == deviceID {
            return engine
        }
        teardownEngine()

        let engine = AVAudioEngine()
        // Accessing inputNode attaches it to the engine graph. prepare() on an
        // engine with an empty graph raises an uncaught ObjC exception
        // ("inputNode != nullptr || outputNode != nullptr") and kills the app,
        // so the node MUST be touched before the first prepare() — including
        // on the default-device path where setInputDevice is skipped.
        let inputNode = engine.inputNode
        if let deviceID {
            try setInputDevice(deviceID, on: inputNode)
        }
        engine.prepare()
        audioEngine = engine
        configuredDeviceID = deviceID
        return engine
    }

    private func teardownEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        configuredDeviceID = nil
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw DictationCaptureError.audioUnitUnavailable
        }
        var id = deviceID
        let status = withUnsafePointer(to: &id) { pointer in
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                pointer,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        guard status == noErr else {
            throw DictationCaptureError.deviceSelectionFailed(status)
        }
    }
}

enum DictationCaptureError: LocalizedError {
    case invalidFormat
    case audioUnitUnavailable
    case deviceSelectionFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Microphone reported an invalid audio format."
        case .audioUnitUnavailable:
            return "Audio input unit is unavailable."
        case .deviceSelectionFailed(let status):
            return "Failed to select audio device (status: \(status))."
        }
    }
}

/// Tap callbacks only copy into this queue. One task owns conversion and output.
/// Each pipeline has a token and permanently closes its queue at stop.
final class DictationAudioPipeline: @unchecked Sendable {
    let generation = UUID()
    let stream: AsyncThrowingStream<[Float], Error>
    private let lock = NSLock()
    private var buffers: [[Float]] = []
    private var closed = false
    private let wake: AsyncStream<Void>.Continuation
    private var consumer: Task<Void, Never>?

    init(converter: any DictationAudioConverting) {
        let output = AsyncThrowingStream<[Float], Error>.makeStream()
        stream = output.stream
        let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = signals.continuation
        consumer = Task { [self] in
            do {
                for await _ in signals.stream {
                    for samples in takeBuffers() {
                        let converted = try converter.convert(samples)
                        if !converted.isEmpty { output.continuation.yield(converted) }
                    }
                }
                let tail = try converter.finish()
                if !tail.isEmpty { output.continuation.yield(tail) }
                output.continuation.finish()
            } catch {
                close(discard: true)
                output.continuation.finish(throwing: error)
            }
        }
    }

    func append(_ samples: [Float], generation: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, generation == self.generation else { return }
        buffers.append(samples)
        wake.yield(())
    }

    private func takeBuffers() -> [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        let pending = buffers
        buffers.removeAll(keepingCapacity: true)
        return pending
    }

    private func close(discard: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        if discard { buffers.removeAll() }
        wake.finish()
    }

    func stop() async {
        close()
        await consumer?.value
    }
}
