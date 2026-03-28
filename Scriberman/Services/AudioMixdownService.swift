import AVFoundation
import CoreMedia
import Foundation

enum AudioMixdownOutputFormat {
    case aacM4A
    case linearPCMCaf
}

actor AudioMixdownService {
    private let outputSampleRate: Double = 48_000
    private let processingChunkSize: AVAudioFrameCount = 4_096
    private let fileManager = FileManager.default
    private let outputFormat: AudioMixdownOutputFormat

    init(outputFormat: AudioMixdownOutputFormat = .aacM4A) {
        self.outputFormat = outputFormat
    }

    func mix(
        micURL: URL,
        appURL: URL?,
        micStartHostTime: UInt64,
        appStartHostTime: UInt64?,
        into outputURL: URL
    ) async throws {
        let micSamples: [Float]
        do {
            micSamples = try readResampledMonoSamples(from: micURL)
        } catch {
            throw RecordingError.failedToStart("Mixdown mic read failed: \(error.localizedDescription)")
        }

        if let appURL {
            let appSamples: [Float]
            do {
                appSamples = try readResampledMonoSamples(from: appURL)
            } catch {
                throw RecordingError.failedToStart("Mixdown app read failed: \(error.localizedDescription)")
            }

            let offsetSamples = computeOffsetSamples(
                micStartHostTime: micStartHostTime,
                appStartHostTime: appStartHostTime
            )

            do {
                try writeStereoAAC(
                    micSamples: micSamples,
                    appSamples: appSamples,
                    appOffsetSamples: offsetSamples,
                    to: outputURL
                )
            } catch {
                throw RecordingError.failedToStart("Mixdown stereo write failed: \(error.localizedDescription)")
            }
        } else {
            do {
                try writeMonoAAC(samples: micSamples, to: outputURL)
            } catch {
                throw RecordingError.failedToStart("Mixdown mono write failed: \(error.localizedDescription)")
            }
        }
    }

    private func readResampledMonoSamples(from inputURL: URL) throws -> [Float] {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let inputFormat = inputFile.processingFormat

        if inputFormat.sampleRate == outputSampleRate,
           inputFormat.channelCount == 1 {
            var directSamples: [Float] = []
            while true {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: processingChunkSize
                ) else {
                    throw RecordingError.failedToStart("Failed to allocate direct-read buffer.")
                }

                try inputFile.read(into: buffer, frameCount: processingChunkSize)
                guard buffer.frameLength > 0 else {
                    return directSamples
                }

                let frameCount = Int(buffer.frameLength)
                let sampleCountBeforeAppend = directSamples.count
                switch inputFormat.commonFormat {
                case .pcmFormatFloat32:
                    if let channelData = buffer.floatChannelData {
                        directSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
                    }
                case .pcmFormatInt16:
                    if let channelData = buffer.int16ChannelData {
                        for index in 0..<frameCount {
                            directSamples.append(Float(channelData[0][index]) / Float(Int16.max))
                        }
                    }
                case .pcmFormatInt32:
                    if let channelData = buffer.int32ChannelData {
                        for index in 0..<frameCount {
                            directSamples.append(Float(channelData[0][index]) / Float(Int32.max))
                        }
                    }
                default:
                    break
                }

                if directSamples.count - sampleCountBeforeAppend < frameCount {
                    throw RecordingError.failedToStart("Unsupported direct-read format: \(inputFormat.commonFormat.rawValue)")
                }
            }
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecordingError.failedToStart("Failed to create target mixdown format.")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecordingError.failedToStart("Failed to create audio converter for mixdown.")
        }

        var allSamples: [Float] = []
        var reachedEndOfInput = false
        var inputReadError: Error?
        var sourceBuffer: AVAudioPCMBuffer?

        while true {
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: processingChunkSize
            ) else {
                throw RecordingError.failedToStart("Failed to allocate mixdown buffer.")
            }

            var conversionError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { [processingChunkSize] _, outputStatus in
                if reachedEndOfInput {
                    outputStatus.pointee = .endOfStream
                    return nil
                }

                guard let readBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: processingChunkSize
                ) else {
                    outputStatus.pointee = .noDataNow
                    return nil
                }

                do {
                    try inputFile.read(into: readBuffer, frameCount: processingChunkSize)
                } catch {
                    inputReadError = error
                    reachedEndOfInput = true
                    outputStatus.pointee = .endOfStream
                    return nil
                }

                if readBuffer.frameLength == 0 {
                    reachedEndOfInput = true
                    outputStatus.pointee = .endOfStream
                    return nil
                }

                sourceBuffer = readBuffer
                outputStatus.pointee = .haveData
                return sourceBuffer
            }

            if let inputReadError {
                throw inputReadError
            }
            if let conversionError {
                throw conversionError
            }

            if convertedBuffer.frameLength > 0, let channelData = convertedBuffer.floatChannelData {
                let frameCount = Int(convertedBuffer.frameLength)
                allSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
            }

            switch status {
            case .error:
                throw RecordingError.failedToStart("Audio conversion failed during mixdown.")
            case .endOfStream:
                return allSamples
            default:
                continue
            }
        }
    }

    private func computeOffsetSamples(
        micStartHostTime: UInt64,
        appStartHostTime: UInt64?
    ) -> Int {
        guard let appStartHostTime else {
            return 0
        }

        let deltaNanoseconds = Double(Int64(appStartHostTime) - Int64(micStartHostTime))
        return Int((deltaNanoseconds / 1_000_000_000.0 * outputSampleRate).rounded())
    }

    private func writeMonoAAC(samples: [Float], to outputURL: URL) throws {
        try removeOutputIfNeeded(outputURL)

        let outputFile = try makeOutputFile(url: outputURL, channelCount: 1)
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: 1) else {
            throw RecordingError.failedToStart("Failed to create mono mixdown format.")
        }

        var index = 0
        while index < samples.count {
            let remaining = samples.count - index
            let frameCount = min(remaining, Int(processingChunkSize))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let channelData = buffer.floatChannelData else {
                throw RecordingError.failedToStart("Failed to allocate mono output buffer.")
            }

            buffer.frameLength = AVAudioFrameCount(frameCount)
            samples[index..<(index + frameCount)].withUnsafeBufferPointer { pointer in
                if let baseAddress = pointer.baseAddress {
                    channelData[0].assign(from: baseAddress, count: frameCount)
                }
            }

            try outputFile.write(from: buffer)
            index += frameCount
        }
    }

    private func writeStereoAAC(
        micSamples: [Float],
        appSamples: [Float],
        appOffsetSamples: Int,
        to outputURL: URL
    ) throws {
        try removeOutputIfNeeded(outputURL)

        let outputFile = try makeOutputFile(url: outputURL, channelCount: 2)
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: 2) else {
            throw RecordingError.failedToStart("Failed to create stereo mixdown format.")
        }

        let micStartFrame = max(0, -appOffsetSamples)
        let appStartFrame = max(0, appOffsetSamples)
        let totalFrames = max(micStartFrame + micSamples.count, appStartFrame + appSamples.count)

        var outputStartFrame = 0
        while outputStartFrame < totalFrames {
            let framesRemaining = totalFrames - outputStartFrame
            let frameCount = min(framesRemaining, Int(processingChunkSize))

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: stereoFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let channelData = buffer.floatChannelData else {
                throw RecordingError.failedToStart("Failed to allocate stereo output buffer.")
            }

            buffer.frameLength = AVAudioFrameCount(frameCount)
            channelData[0].initialize(repeating: 0, count: frameCount)
            channelData[1].initialize(repeating: 0, count: frameCount)

            for frameOffset in 0..<frameCount {
                let frameIndex = outputStartFrame + frameOffset

                let micIndex = frameIndex - micStartFrame
                if micIndex >= 0, micIndex < micSamples.count {
                    channelData[0][frameOffset] = micSamples[micIndex]
                }

                let appIndex = frameIndex - appStartFrame
                if appIndex >= 0, appIndex < appSamples.count {
                    channelData[1][frameOffset] = appSamples[appIndex]
                }
            }

            try outputFile.write(from: buffer)
            outputStartFrame += frameCount
        }
    }

    private func removeOutputIfNeeded(_ outputURL: URL) throws {
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
    }

    private func outputSettings(channelCount: Int) -> [String: Any] {
        switch outputFormat {
        case .aacM4A:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: outputSampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        case .linearPCMCaf:
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputSampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ) else {
                return [:]
            }
            return format.settings
        }
    }

    private func makeOutputFile(url: URL, channelCount: Int) throws -> AVAudioFile {
        let settings = outputSettings(channelCount: channelCount)
        if outputFormat == .linearPCMCaf {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputSampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ) else {
                throw RecordingError.failedToStart("Failed to create PCM output format.")
            }
            return try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        }

        return try AVAudioFile(forWriting: url, settings: settings)
    }
}
