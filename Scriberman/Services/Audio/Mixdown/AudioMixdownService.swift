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
        into outputURL: URL,
        deleteSourceFiles: Bool = true
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
        if deleteSourceFiles {
            deleteSourceWAVFiles(micURL: micURL, appURL: appURL)
        }
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
        let channelCount = Int(inputFormat.channelCount)
        guard channelCount > 0 else {
            throw RecordingError.failedToStart("Invalid channel count while reading mixdown input.")
        }

        var monoSamplesAtSourceRate: [Float] = []
        while true {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: processingChunkSize
            ) else {
                throw RecordingError.failedToStart("Failed to allocate direct-read buffer.")
            }

            try inputFile.read(into: buffer, frameCount: processingChunkSize)
            guard buffer.frameLength > 0 else {
                break
            }

            let frameCount = Int(buffer.frameLength)
            let writeStart = monoSamplesAtSourceRate.count
            monoSamplesAtSourceRate.append(contentsOf: repeatElement(0, count: frameCount))
            let channelScale = Float(1.0 / Double(channelCount))

            switch inputFormat.commonFormat {
            case .pcmFormatFloat32:
                guard let channelData = buffer.floatChannelData else {
                    throw RecordingError.failedToStart("Missing float channel data while reading mixdown input.")
                }
                for channelIndex in 0..<channelCount {
                    let channel = UnsafeBufferPointer(start: channelData[channelIndex], count: frameCount)
                    for sampleIndex in 0..<frameCount {
                        monoSamplesAtSourceRate[writeStart + sampleIndex] += channel[sampleIndex] * channelScale
                    }
                }
            case .pcmFormatInt16:
                guard let channelData = buffer.int16ChannelData else {
                    throw RecordingError.failedToStart("Missing int16 channel data while reading mixdown input.")
                }
                let maxValue = Float(Int16.max)
                for channelIndex in 0..<channelCount {
                    let channel = UnsafeBufferPointer(start: channelData[channelIndex], count: frameCount)
                    for sampleIndex in 0..<frameCount {
                        monoSamplesAtSourceRate[writeStart + sampleIndex] += (Float(channel[sampleIndex]) / maxValue) * channelScale
                    }
                }
            case .pcmFormatInt32:
                guard let channelData = buffer.int32ChannelData else {
                    throw RecordingError.failedToStart("Missing int32 channel data while reading mixdown input.")
                }
                let maxValue = Float(Int32.max)
                for channelIndex in 0..<channelCount {
                    let channel = UnsafeBufferPointer(start: channelData[channelIndex], count: frameCount)
                    for sampleIndex in 0..<frameCount {
                        monoSamplesAtSourceRate[writeStart + sampleIndex] += (Float(channel[sampleIndex]) / maxValue) * channelScale
                    }
                }
            default:
                throw RecordingError.failedToStart("Unsupported input common format for mixdown: \(inputFormat.commonFormat.rawValue)")
            }
        }

        if abs(inputFormat.sampleRate - outputSampleRate) < 0.0001 {
            return monoSamplesAtSourceRate
        }
        return try resampleMonoSamples(
            monoSamplesAtSourceRate,
            sourceSampleRate: inputFormat.sampleRate
        )
    }

    private func resampleMonoSamples(_ samples: [Float], sourceSampleRate: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ), let targetFormat = AVAudioFormat(
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

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let inputChannelData = inputBuffer.floatChannelData else {
            throw RecordingError.failedToStart("Failed to allocate mixdown input buffer.")
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            inputChannelData[0].update(from: baseAddress, count: samples.count)
        }

        var deliveredInput = false
        var outputSamples: [Float] = []
        while true {
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: processingChunkSize
            ) else {
                throw RecordingError.failedToStart("Failed to allocate mixdown buffer.")
            }

            var conversionError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outputStatus in
                if deliveredInput {
                    outputStatus.pointee = .endOfStream
                    return nil
                }
                deliveredInput = true
                outputStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw conversionError
            }
            if convertedBuffer.frameLength > 0, let channelData = convertedBuffer.floatChannelData {
                let frameCount = Int(convertedBuffer.frameLength)
                outputSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
            }

            switch status {
            case .error:
                throw RecordingError.failedToStart("Audio conversion failed during mixdown.")
            case .endOfStream:
                return outputSamples
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

        var fileFormat = AudioStreamBasicDescription()
        var fileFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fileFormatStatus = ExtAudioFileGetProperty(
            extAudioFile,
            kExtAudioFileProperty_FileDataFormat,
            &fileFormatSize,
            &fileFormat
        )
        guard fileFormatStatus == noErr else {
            throw RecordingError.failedToStart(
                "ExtAudioFileGetProperty(FileDataFormat) failed for \(label): \(fileFormatStatus)"
            )
        }
        let sourceChannelCount = max(1, Int(fileFormat.mChannelsPerFrame))
        let bytesPerFrame = sourceChannelCount * MemoryLayout<Float>.size

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(sourceChannelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let clientFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
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
        var chunk = [Float](repeating: 0, count: chunkSize * sourceChannelCount)

        while true {
            var frames = UInt32(chunkSize)
            let status = chunk.withUnsafeMutableBufferPointer { buffer -> OSStatus in
                var audioBufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(sourceChannelCount),
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
            let frameCount = Int(frames)
            let channelScale = Float(1.0 / Double(sourceChannelCount))
            for frameIndex in 0..<frameCount {
                var mixed: Float = 0
                let baseIndex = frameIndex * sourceChannelCount
                for channelIndex in 0..<sourceChannelCount {
                    mixed += chunk[baseIndex + channelIndex] * channelScale
                }
                samples.append(mixed)
            }
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

    func writeMonoAAC(samples: [Float], to outputURL: URL) throws {
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
                    channelData[0].update(from: baseAddress, count: frameCount)
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
