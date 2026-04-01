import AVFoundation
import Foundation

enum M4AChannelExtractorError: LocalizedError {
    case fileNotFound(String)
    case failedToOpenFile(String)
    case failedToReadFile(String)
    case invalidChannelCount(expectedStereo: Bool, actual: Int)
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
        case .conversionFailed(let reason):
            return "Failed to resample audio: \(reason)"
        }
    }
}

struct M4AChannelExtractor {
    private let targetSampleRate: Double = 16_000
    private let resampler = AudioResampler(targetSampleRate: 16_000)
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
            throw M4AChannelExtractorError.failedToReadFile("Failed to allocate buffer for extraction.")
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
        let mic = try resample(micRaw, sourceSampleRate: buffer.format.sampleRate)

        if isStereo {
            let appRaw = Array(UnsafeBufferPointer(start: floatChannelData[1], count: frameCount))
            let app = try resample(appRaw, sourceSampleRate: buffer.format.sampleRate)
            return (mic: mic, app: app)
        }

        return (mic: mic, app: nil)
    }

    private func resample(_ samples: [Float], sourceSampleRate: Double) throws -> [Float] {
        do {
            return try resampler.resample(samples, from: sourceSampleRate)
        } catch {
            throw M4AChannelExtractorError.conversionFailed(error.localizedDescription)
        }
    }
}
