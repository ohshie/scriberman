import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Capture abstraction so `DictationService` state logic is unit-testable
/// without a live microphone.
protocol DictationCapturing: Sendable {
    func start(deviceID: AudioDeviceID?) async throws -> AsyncStream<[Float]>
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
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var levelHandler: (@Sendable (Float) -> Void)?

    func setLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {
        levelHandler = handler
    }

    // Starts the mic tap for the given device (nil = system default).
    // Returns an AsyncStream of mono 16 kHz Float samples.
    func start(deviceID: AudioDeviceID?) throws -> AsyncStream<[Float]> {
        endCapture()

        let normalizedDeviceID = (deviceID != nil && deviceID != 0) ? deviceID : nil
        let engine = try engineReady(for: normalizedDeviceID)

        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.continuation = continuation

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            continuation.finish()
            self.continuation = nil
            teardownEngine()
            throw DictationCaptureError.invalidFormat
        }

        let resampler = AudioResampler(targetSampleRate: Self.targetSampleRate)
        let sourceSampleRate = inputFormat.sampleRate
        let reportLevel = levelHandler

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            let mono = AudioDownmixer.toMono(buffer: buffer)
            guard !mono.isEmpty else { return }
            if let reportLevel {
                var sumOfSquares: Float = 0
                for sample in mono {
                    sumOfSquares += sample * sample
                }
                reportLevel(sqrt(sumOfSquares / Float(mono.count)))
            }
            let resampled = (try? resampler.resample(mono, from: sourceSampleRate)) ?? mono
            guard !resampled.isEmpty else { return }
            Task { await self?.emit(resampled) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            continuation.finish()
            self.continuation = nil
            teardownEngine()
            throw error
        }
        logger.info("Dictation capture started (device: \(normalizedDeviceID.map { String($0) } ?? "default"))")
        return stream
    }

    func stop() {
        endCapture()
        logger.info("Dictation capture stopped (engine retained)")
    }

    // Stops the current tap/stream but retains the prepared engine for reuse.
    private func endCapture() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        continuation?.finish()
        continuation = nil
    }

    private func engineReady(for deviceID: AudioDeviceID?) throws -> AVAudioEngine {
        if let engine = audioEngine, configuredDeviceID == deviceID {
            return engine
        }
        teardownEngine()

        let engine = AVAudioEngine()
        if let deviceID {
            try setInputDevice(deviceID, on: engine.inputNode)
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

    private func emit(_ samples: [Float]) {
        continuation?.yield(samples)
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
