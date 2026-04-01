import AVFoundation
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

        var deliveredInput = false
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
                if deliveredInput {
                    outputStatus.pointee = .endOfStream
                    return nil
                }
                deliveredInput = true
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
