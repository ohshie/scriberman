import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import OSLog

enum AudioMixdownOutputFormat {
    case aacM4A
    case linearPCMCaf
}

actor AudioMixdownService {
    typealias RemoveItemAtURL = @Sendable (URL) throws -> Void

    private let outputSampleRate: Double = 48_000
    private let processingChunkSize: AVAudioFrameCount = 4_096
    private let fileManager = FileManager.default
    private let outputFormat: AudioMixdownOutputFormat
    private let removeItemAtURL: RemoveItemAtURL
    private let logger = Logger(subsystem: "Scriberman", category: "AudioMixdownService")

    init(
        outputFormat: AudioMixdownOutputFormat = .aacM4A,
        removeItemAtURL: @escaping RemoveItemAtURL = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) {
        self.outputFormat = outputFormat
        self.removeItemAtURL = removeItemAtURL
    }

    func mix(
        micURL: URL,
        appURL: URL?,
        micStartHostTime: UInt64,
        appStartHostTime: UInt64?,
        into outputURL: URL
    ) async throws {
        logger.info(
            "Mix request received. mic=\(micURL.path, privacy: .public) app=\(appURL?.path ?? "nil", privacy: .public) out=\(outputURL.path, privacy: .public) format=\(String(describing: self.outputFormat), privacy: .public)"
        )
        logger.info(
            "Mix timing input. micStart=\(micStartHostTime, privacy: .public) appStart=\(appStartHostTime ?? 0, privacy: .public)"
        )
        logger.info(
            "Input existence. micExists=\(self.fileManager.fileExists(atPath: micURL.path), privacy: .public) appExists=\(appURL.map { self.fileManager.fileExists(atPath: $0.path) } ?? false, privacy: .public)"
        )

        let micSamples = try await readSamplesWithRetry(from: micURL, label: "mic")
        logger.info("Mic samples loaded. count=\(micSamples.count, privacy: .public)")

        if let appURL {
            let appSamples = try await readSamplesWithRetry(from: appURL, label: "app")
            logger.info("App samples loaded. count=\(appSamples.count, privacy: .public)")

            let offsetSamples = computeOffsetSamples(
                micStartHostTime: micStartHostTime,
                appStartHostTime: appStartHostTime
            )
            logger.info("Computed stereo offsetSamples=\(offsetSamples, privacy: .public)")

            do {
                try writeStereoAAC(
                    micSamples: micSamples,
                    appSamples: appSamples,
                    appOffsetSamples: offsetSamples,
                    to: outputURL
                )
                logger.info("Stereo write completed to \(outputURL.path, privacy: .public)")
            } catch {
                logger.error("Stereo write failed: \(error.localizedDescription, privacy: .public)")
                throw RecordingError.failedToStart("Mixdown stereo write failed: \(error.localizedDescription)")
            }
        } else {
            do {
                try writeMonoAAC(samples: micSamples, to: outputURL)
                logger.info("Mono write completed to \(outputURL.path, privacy: .public)")
            } catch {
                logger.error("Mono write failed: \(error.localizedDescription, privacy: .public)")
                throw RecordingError.failedToStart("Mixdown mono write failed: \(error.localizedDescription)")
            }
        }

        logger.info("Mix completed. outputExists=\(self.fileManager.fileExists(atPath: outputURL.path), privacy: .public)")
        deleteSourceWAVFiles(micURL: micURL, appURL: appURL)
    }

    private func deleteSourceWAVFiles(micURL: URL, appURL: URL?) {
        deleteSourceWAVFile(url: micURL, label: "mic")
        if let appURL {
            deleteSourceWAVFile(url: appURL, label: "app")
        }
    }

    private func deleteSourceWAVFile(url: URL, label: String) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        do {
            try removeItemAtURL(url)
            logger.info("Deleted \(label, privacy: .public) wav at \(url.path, privacy: .public)")
        } catch {
            logger.error("Failed to delete \(label, privacy: .public) wav at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readSamplesWithRetry(from url: URL, label: String) async throws -> [Float] {
        let maxAttempts = 3
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                if attempt > 1 {
                    logger.info("Retrying \(label, privacy: .public) read attempt \(attempt, privacy: .public)")
                }
                return try readSamplesWithFallback(from: url, label: label)
            } catch {
                lastError = error
                let nsError = error as NSError
                logger.error(
                    "\(label, privacy: .public) read attempt \(attempt, privacy: .public) failed. domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) desc=\(nsError.localizedDescription, privacy: .public)"
                )
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
        }

        let fallbackDescription = lastError?.localizedDescription ?? "unknown"
        throw RecordingError.failedToStart("Mixdown \(label) read failed: \(fallbackDescription)")
    }

    private func readSamplesWithFallback(from inputURL: URL, label: String) throws -> [Float] {
        do {
            return try readResampledMonoSamplesViaAVAudioFile(from: inputURL)
        } catch {
            let nsError = error as NSError
            logger.error(
                "\(label, privacy: .public) AVAudioFile read path failed. domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) desc=\(nsError.localizedDescription, privacy: .public). Falling back to ExtAudioFile."
            )
            return try readResampledMonoSamplesViaExtAudioFile(from: inputURL, label: label)
        }
    }

    private func readResampledMonoSamplesViaAVAudioFile(from inputURL: URL) throws -> [Float] {
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: inputURL)
        } catch {
            let nsError = error as NSError
            logger.error(
                "AVAudioFile(forReading:) failed for \(inputURL.path, privacy: .public). domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) desc=\(nsError.localizedDescription, privacy: .public). Retrying with explicit decode format."
            )
            do {
                inputFile = try AVAudioFile(
                    forReading: inputURL,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            } catch {
                let fallbackError = error as NSError
                logger.error(
                    "AVAudioFile explicit decode fallback failed for \(inputURL.path, privacy: .public). domain=\(fallbackError.domain, privacy: .public) code=\(fallbackError.code, privacy: .public) desc=\(fallbackError.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }
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

    private func readResampledMonoSamplesViaExtAudioFile(from inputURL: URL, label: String) throws -> [Float] {
        var extAudioFile: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(inputURL as CFURL, &extAudioFile)
        guard openStatus == noErr, let extAudioFile else {
            throw RecordingError.failedToStart(
                "ExtAudioFileOpenURL failed for \(label): \(openStatus)"
            )
        }
        defer { ExtAudioFileDispose(extAudioFile) }

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var clientFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let setFormatStatus = ExtAudioFileSetProperty(
            extAudioFile,
            kExtAudioFileProperty_ClientDataFormat,
            clientFormatSize,
            &clientFormat
        )
        guard setFormatStatus == noErr else {
            throw RecordingError.failedToStart(
                "ExtAudioFileSetProperty(ClientDataFormat) failed for \(label): \(setFormatStatus)"
            )
        }

        var samples: [Float] = []
        let chunkSize = Int(processingChunkSize)
        var chunk = [Float](repeating: 0, count: chunkSize)

        while true {
            var frames = UInt32(chunkSize)
            let status = chunk.withUnsafeMutableBufferPointer { buffer -> OSStatus in
                var audioBufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.size),
                        mData: buffer.baseAddress
                    )
                )
                return ExtAudioFileRead(extAudioFile, &frames, &audioBufferList)
            }
            guard status == noErr else {
                throw RecordingError.failedToStart("ExtAudioFileRead failed for \(label): \(status)")
            }
            if frames == 0 {
                break
            }
            samples.append(contentsOf: chunk.prefix(Int(frames)))
        }

        logger.info(
            "\(label, privacy: .public) ExtAudioFile fallback succeeded. sampleCount=\(samples.count, privacy: .public)"
        )
        return samples
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
