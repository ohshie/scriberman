import AVFoundation
import CoreAudio
import Foundation
import OSLog

actor DictationCaptureSession {
    private let logger = Logger(subsystem: "Scriberman", category: "DictationCapture")
    private static let targetSampleRate: Double = 16_000

    private var audioEngine: AVAudioEngine?
    private var continuation: AsyncStream<[Float]>.Continuation?

    // Starts the mic tap for the given device (nil = system default).
    // Returns an AsyncStream of mono 16 kHz Float samples.
    func start(deviceID: AudioDeviceID?) throws -> AsyncStream<[Float]> {
        stop()

        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.continuation = continuation

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if let deviceID, deviceID != 0 {
            try setInputDevice(deviceID, on: inputNode)
        }

        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            continuation.finish()
            throw DictationCaptureError.invalidFormat
        }

        let resampler = AudioResampler(targetSampleRate: Self.targetSampleRate)
        let sourceSampleRate = inputFormat.sampleRate

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            let mono = AudioDownmixer.toMono(buffer: buffer)
            guard !mono.isEmpty else { return }
            let resampled = (try? resampler.resample(mono, from: sourceSampleRate)) ?? mono
            guard !resampled.isEmpty else { return }
            Task { await self?.emit(resampled) }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
        logger.info("Dictation capture started (device: \(deviceID.map { String($0) } ?? "default"))")
        return stream
    }

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        continuation?.finish()
        continuation = nil
        logger.info("Dictation capture stopped")
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
