import AVFoundation
import Foundation

enum M4AChannelExtractorError: LocalizedError {
    case fileNotFound(String)
    case failedToOpenFile(String)
    case failedToReadFile(String)
    case invalidChannelCount(expectedStereo: Bool, actual: Int)
    case failedToCreateFormat
    case failedToCreateConverter
    case failedToAllocateBuffer
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Audio file not found at \(path)"
        case .failedToOpenFile(let reason):
            return "Failed to open audio file: \(reason)"
        case .failedToReadFile(let reason):
            return "Failed to read audio file: \(reason)"
        case .invalidChannelCount(let expectedStereo, let actual):
            if expectedStereo {
                return "Expected stereo audio with at least 2 channels, got \(actual)"
            }
            return "Expected mono or stereo audio with at least 1 channel, got \(actual)"
        case .failedToCreateFormat:
            return "Failed to create audio format for resampling."
        case .failedToCreateConverter:
            return "Failed to create audio converter for resampling."
        case .failedToAllocateBuffer:
            return "Failed to allocate audio buffer."
        case .conversionFailed(let reason):
            return "Failed to resample audio: \(reason)"
        }
    }
}

struct M4AChannelExtractor {
    private let targetSampleRate: Double = 16_000
    private let conversionChunkSize: AVAudioFrameCount = 4_096
    private let fileManager = FileManager.default

    func extract(url: URL, isStereo: Bool) throws -> (mic: [Float], app: [Float]?) {
        guard fileManager.fileExists(atPath: url.path) else {
            throw M4AChannelExtractorError.fileNotFound(url.path)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw M4AChannelExtractorError.failedToOpenFile(error.localizedDescription)
        }

        guard file.length > 0 else {
            return (mic: [], app: isStereo ? [] : nil)
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw M4AChannelExtractorError.failedToAllocateBuffer
        }

        do {
            try file.read(into: buffer)
        } catch {
            throw M4AChannelExtractorError.failedToReadFile(error.localizedDescription)
        }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount >= (isStereo ? 2 : 1) else {
            throw M4AChannelExtractorError.invalidChannelCount(expectedStereo: isStereo, actual: channelCount)
        }
        guard let floatChannelData = buffer.floatChannelData else {
            throw M4AChannelExtractorError.failedToReadFile("Missing float channel data.")
        }

        let frameCount = Int(buffer.frameLength)
        let micRaw = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameCount))
        let mic = try resample(samples: micRaw, sourceSampleRate: buffer.format.sampleRate)

        if isStereo {
            let appRaw = Array(UnsafeBufferPointer(start: floatChannelData[1], count: frameCount))
            let app = try resample(samples: appRaw, sourceSampleRate: buffer.format.sampleRate)
            return (mic: mic, app: app)
        }

        return (mic: mic, app: nil)
    }

    private func resample(samples: [Float], sourceSampleRate: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
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
            throw M4AChannelExtractorError.failedToCreateFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw M4AChannelExtractorError.failedToCreateConverter
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let inputChannelData = inputBuffer.floatChannelData else {
            throw M4AChannelExtractorError.failedToAllocateBuffer
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            inputChannelData[0].assign(from: baseAddress, count: samples.count)
        }

        var deliveredInput = false
        var outputSamples: [Float] = []

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: conversionChunkSize
            ) else {
                throw M4AChannelExtractorError.failedToAllocateBuffer
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if deliveredInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                deliveredInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw M4AChannelExtractorError.conversionFailed(conversionError.localizedDescription)
            }

            if outputBuffer.frameLength > 0, let outputChannelData = outputBuffer.floatChannelData {
                let count = Int(outputBuffer.frameLength)
                outputSamples.append(contentsOf: UnsafeBufferPointer(start: outputChannelData[0], count: count))
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                continue
            case .endOfStream:
                let expectedCount = Int(floor(Double(samples.count) * (targetSampleRate / sourceSampleRate)))
                if expectedCount > 0, outputSamples.count > expectedCount {
                    outputSamples = Array(outputSamples.prefix(expectedCount))
                }
                return outputSamples
            case .error:
                throw M4AChannelExtractorError.conversionFailed("Audio converter returned error status.")
            @unknown default:
                throw M4AChannelExtractorError.conversionFailed("Audio converter returned unknown status.")
            }
        }
    }
}
