@preconcurrency import AVFoundation
import Foundation

enum AudioResamplerError: LocalizedError {
    case failedToCreateFormat
    case failedToCreateConverter
    case failedToAllocateBuffer
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .failedToCreateFormat:
            return "Failed to create audio format for resampling."
        case .failedToCreateConverter:
            return "Failed to create audio converter for resampling."
        case .failedToAllocateBuffer:
            return "Failed to allocate audio buffer for resampling."
        case .conversionFailed(let reason):
            return "Failed to resample audio: \(reason)"
        }
    }
}

struct AudioResampler {
    private final class ConversionState: @unchecked Sendable {
        var deliveredInput = false
    }

    let targetSampleRate: Double
    private let conversionChunkSize: AVAudioFrameCount = 4_096

    init(targetSampleRate: Double) {
        self.targetSampleRate = targetSampleRate
    }

    func resample(_ samples: [Float], from sourceSampleRate: Double) throws -> [Float] {
        guard !samples.isEmpty else {
            return []
        }
        if abs(sourceSampleRate - targetSampleRate) < 0.0001 {
            return samples
        }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioResamplerError.failedToCreateFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioResamplerError.failedToCreateConverter
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let inputChannelData = inputBuffer.floatChannelData else {
            throw AudioResamplerError.failedToAllocateBuffer
        }

        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else {
                return
            }
            inputChannelData[0].update(from: baseAddress, count: samples.count)
        }

        let conversionState = ConversionState()
        var outputSamples: [Float] = []

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: conversionChunkSize
            ) else {
                throw AudioResamplerError.failedToAllocateBuffer
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
                if conversionState.deliveredInput {
                    outputStatus.pointee = .endOfStream
                    return nil
                }
                conversionState.deliveredInput = true
                outputStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw AudioResamplerError.conversionFailed(conversionError.localizedDescription)
            }

            if outputBuffer.frameLength > 0, let outputChannelData = outputBuffer.floatChannelData {
                let frameCount = Int(outputBuffer.frameLength)
                outputSamples.append(contentsOf: UnsafeBufferPointer(start: outputChannelData[0], count: frameCount))
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                continue
            case .endOfStream:
                let expectedCount = Int(floor(Double(samples.count) * (targetSampleRate / sourceSampleRate)))
                if expectedCount > 0, outputSamples.count > expectedCount {
                    return Array(outputSamples.prefix(expectedCount))
                }
                return outputSamples
            case .error:
                throw AudioResamplerError.conversionFailed("Audio converter returned error status.")
            @unknown default:
                throw AudioResamplerError.conversionFailed("Audio converter returned unknown status.")
            }
        }
    }
}

/// Used only by the dictation drain task. Input exhaustion between callbacks is
/// temporary; end-of-stream is sent once, after capture has stopped.
protocol DictationAudioConverting: Sendable {
    func convert(_ samples: [Float]) throws -> [Float]
    func finish() throws -> [Float]
}

final class ContinuousAudioResampler: DictationAudioConverting, @unchecked Sendable {
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var ended = false

    private final class InputState: @unchecked Sendable {
        var delivered = false
    }

    init(sourceSampleRate: Double, targetSampleRate: Double = 16_000) throws {
        guard let source = AVAudioFormat(standardFormatWithSampleRate: sourceSampleRate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1) else {
            throw AudioResamplerError.failedToCreateFormat
        }
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw AudioResamplerError.failedToCreateConverter
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 1_024),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4_096) else {
            throw AudioResamplerError.failedToAllocateBuffer
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.converter = converter
        self.input = input
        self.output = output
    }

    func convert(_ samples: [Float]) throws -> [Float] {
        guard !ended else { return [] }
        var result: [Float] = []
        for offset in stride(from: 0, to: samples.count, by: Int(input.frameCapacity)) {
            let count = min(Int(input.frameCapacity), samples.count - offset)
            input.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { buffer in
                input.floatChannelData![0].update(from: buffer.baseAddress! + offset, count: count)
            }
            result.append(contentsOf: try drain(endOfStream: false))
        }
        return result
    }

    func finish() throws -> [Float] {
        guard !ended else { return [] }
        ended = true
        return try drain(endOfStream: true)
    }

    private func drain(endOfStream: Bool) throws -> [Float] {
        let state = InputState()
        let input = self.input
        var result: [Float] = []
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                if endOfStream {
                    status.pointee = .endOfStream
                    return nil
                }
                guard !state.delivered else {
                    status.pointee = .noDataNow
                    return nil
                }
                state.delivered = true
                status.pointee = .haveData
                return input
            }
            if let error { throw AudioResamplerError.conversionFailed(error.localizedDescription) }
            if status == .error { throw AudioResamplerError.conversionFailed("Audio converter returned error status.") }
            if let channel = output.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            switch status {
            case .haveData: continue
            case .inputRanDry, .endOfStream: return result
            case .error: throw AudioResamplerError.conversionFailed("Audio converter returned error status.")
            @unknown default: throw AudioResamplerError.conversionFailed("Audio converter returned unknown status.")
            }
        }
    }
}
