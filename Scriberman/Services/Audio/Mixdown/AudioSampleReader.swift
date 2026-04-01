import AVFoundation
import AudioToolbox
import Foundation
import OSLog

actor AudioSampleReader {
    typealias AVAudioFileReadHandler = @Sendable (URL) throws -> [Float]
    typealias ExtAudioFileReadHandler = @Sendable (URL, String) throws -> [Float]
    typealias Sleep = @Sendable (Duration) async -> Void

    private let outputSampleRate: Double
    private let processingChunkSize: AVAudioFrameCount
    private let resampler: AudioResampler
    private let avAudioFileReadHandler: AVAudioFileReadHandler?
    private let extAudioFileReadHandler: ExtAudioFileReadHandler?
    private let sleep: Sleep
    private let logger = Logger(subsystem: "Scriberman", category: "AudioSampleReader")

    init(
        outputSampleRate: Double = 48_000,
        processingChunkSize: AVAudioFrameCount = 4_096,
        avAudioFileRead: AVAudioFileReadHandler? = nil,
        extAudioFileRead: ExtAudioFileReadHandler? = nil,
        sleep: @escaping Sleep = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.outputSampleRate = outputSampleRate
        self.processingChunkSize = processingChunkSize
        resampler = AudioResampler(targetSampleRate: outputSampleRate)
        avAudioFileReadHandler = avAudioFileRead
        extAudioFileReadHandler = extAudioFileRead
        self.sleep = sleep
    }

    func read(from url: URL, label: String) async throws -> [Float] {
        try await readSamplesWithRetry(from: url, label: label)
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
                    await sleep(.milliseconds(120))
                }
            }
        }

        let fallbackDescription = lastError?.localizedDescription ?? "unknown"
        throw RecordingError.failedToStart("Mixdown \(label) read failed: \(fallbackDescription)")
    }

    private func readSamplesWithFallback(from inputURL: URL, label: String) throws -> [Float] {
        do {
            if let avAudioFileReadHandler {
                return try avAudioFileReadHandler(inputURL)
            }
            return try readResampledMonoSamplesViaAVAudioFile(from: inputURL)
        } catch {
            let nsError = error as NSError
            logger.error(
                "\(label, privacy: .public) AVAudioFile read path failed. domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) desc=\(nsError.localizedDescription, privacy: .public). Falling back to ExtAudioFile."
            )

            if let extAudioFileReadHandler {
                return try extAudioFileReadHandler(inputURL, label)
            }
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
            let monoSamples = try monoSamplesFromBuffer(
                buffer,
                inputFormat: inputFormat,
                frameCount: frameCount,
                channelCount: channelCount
            )
            monoSamplesAtSourceRate.append(contentsOf: monoSamples)
        }

        if abs(inputFormat.sampleRate - outputSampleRate) < 0.0001 {
            return monoSamplesAtSourceRate
        }
        return try resampler.resample(monoSamplesAtSourceRate, from: inputFormat.sampleRate)
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
            var channelSamples = Array(repeating: [Float](), count: sourceChannelCount)
            for channelIndex in 0..<sourceChannelCount {
                channelSamples[channelIndex].reserveCapacity(frameCount)
            }
            for frameIndex in 0..<frameCount {
                let baseIndex = frameIndex * sourceChannelCount
                for channelIndex in 0..<sourceChannelCount {
                    channelSamples[channelIndex].append(chunk[baseIndex + channelIndex])
                }
            }
            samples.append(contentsOf: AudioDownmixer.toMono(channelSamples: channelSamples))
        }

        logger.info(
            "\(label, privacy: .public) ExtAudioFile fallback succeeded. sampleCount=\(samples.count, privacy: .public)"
        )
        return samples
    }

    private func monoSamplesFromBuffer(
        _ buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        frameCount: Int,
        channelCount: Int
    ) throws -> [Float] {
        let stride = max(1, buffer.stride)

        switch inputFormat.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else {
                throw RecordingError.failedToStart("Missing float channel data while reading mixdown input.")
            }
            let channelSamples = (0..<channelCount).map { channelIndex in
                (0..<frameCount).map { frameIndex in
                    channelData[channelIndex][frameIndex * stride]
                }
            }
            return AudioDownmixer.toMono(channelSamples: channelSamples)

        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else {
                throw RecordingError.failedToStart("Missing int16 channel data while reading mixdown input.")
            }
            let maxValue = Float(Int16.max)
            let channelSamples = (0..<channelCount).map { channelIndex in
                (0..<frameCount).map { frameIndex in
                    Float(channelData[channelIndex][frameIndex * stride]) / maxValue
                }
            }
            return AudioDownmixer.toMono(channelSamples: channelSamples)

        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData else {
                throw RecordingError.failedToStart("Missing int32 channel data while reading mixdown input.")
            }
            let maxValue = Float(Int32.max)
            let channelSamples = (0..<channelCount).map { channelIndex in
                (0..<frameCount).map { frameIndex in
                    Float(channelData[channelIndex][frameIndex * stride]) / maxValue
                }
            }
            return AudioDownmixer.toMono(channelSamples: channelSamples)

        default:
            throw RecordingError.failedToStart("Unsupported input common format for mixdown: \(inputFormat.commonFormat.rawValue)")
        }
    }
}
