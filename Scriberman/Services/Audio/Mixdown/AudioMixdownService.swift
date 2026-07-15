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
    private let sampleReader: AudioSampleReader
    private let logger = Logger(subsystem: "Scriberman", category: "AudioMixdownService")

    init(
        outputFormat: AudioMixdownOutputFormat = .aacM4A,
        sampleReader: AudioSampleReader = AudioSampleReader(),
        removeItemAtURL: @escaping RemoveItemAtURL = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) {
        self.outputFormat = outputFormat
        self.sampleReader = sampleReader
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

        let micSamples = try await sampleReader.read(from: micURL, label: "mic")
        logger.info("Mic samples loaded. count=\(micSamples.count, privacy: .public)")

        if AudioSyncConfig.isTimelineMixdownEnabled {
            if try await attemptTimelineMix(micURL: micURL, appURL: appURL, micSamples: micSamples, into: outputURL) {
                logger.info("Used timeline (PTS-anchored) mixdown path.")
                logger.info("Mix completed. outputExists=\(self.fileManager.fileExists(atPath: outputURL.path), privacy: .public)")
                if deleteSourceFiles {
                    deleteSourceWAVFiles(micURL: micURL, appURL: appURL)
                }
                return
            }
            logger.warning("Timeline mixdown unavailable or inconsistent; falling back to legacy constant-offset path.")
        }

        if let appURL {
            let appSamples = try await sampleReader.read(from: appURL, label: "app")
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
        // Remove the timing sidecar (best-effort) alongside the source wav.
        let sidecarURL = AudioFileStreamer.timingSidecarURL(for: url)
        if fileManager.fileExists(atPath: sidecarURL.path) {
            try? removeItemAtURL(sidecarURL)
        }

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

    /// PTS-anchored mixdown: re-places each source's file samples onto a shared real-time
    /// timeline using its `.timing` sidecar (gap-filling silence), then overlays the two
    /// aligned timelines with no residual offset. Returns false (fall back to legacy) when a
    /// sidecar is missing or its frame total disagrees with the decoded sample count.
    private func attemptTimelineMix(
        micURL: URL,
        appURL: URL?,
        micSamples: [Float],
        into outputURL: URL
    ) async throws -> Bool {
        guard let micSidecar = AudioFileStreamer.loadTimingSidecar(for: micURL),
              let micFirstSegment = micSidecar.segments.first else {
            return false
        }
        guard micSidecar.totalFrames == micSamples.count else {
            logger.warning(
                "Mic timing frames (\(micSidecar.totalFrames, privacy: .public)) != decoded samples (\(micSamples.count, privacy: .public)); cannot trust timeline."
            )
            return false
        }

        guard let appURL else {
            let micTimeline = SynchronizedAudioTimeline.reconstruct(
                samples: micSamples,
                segments: micSidecar.segments,
                referenceHostTimeNanos: micFirstSegment.startHostTimeNanos,
                sampleRate: outputSampleRate
            )
            logger.info("Timeline mono. silenceFrames=\(micTimeline.insertedSilenceFrames, privacy: .public) gaps=\(micTimeline.gapCount, privacy: .public)")
            try writeMonoAAC(samples: micTimeline.frames, to: outputURL)
            return true
        }

        guard let appSidecar = AudioFileStreamer.loadTimingSidecar(for: appURL),
              let appFirstSegment = appSidecar.segments.first else {
            return false
        }
        let appSamples = try await sampleReader.read(from: appURL, label: "app")
        guard appSidecar.totalFrames == appSamples.count else {
            logger.warning(
                "App timing frames (\(appSidecar.totalFrames, privacy: .public)) != decoded samples (\(appSamples.count, privacy: .public)); cannot trust timeline."
            )
            return false
        }

        let reference = min(micFirstSegment.startHostTimeNanos, appFirstSegment.startHostTimeNanos)
        let micLeadMs = Double(micFirstSegment.startHostTimeNanos - reference) / 1_000_000.0
        let appLeadMs = Double(appFirstSegment.startHostTimeNanos - reference) / 1_000_000.0
        logger.info(
            "Timeline anchors. micFirstNanos=\(micFirstSegment.startHostTimeNanos, privacy: .public) appFirstNanos=\(appFirstSegment.startHostTimeNanos, privacy: .public) referenceNanos=\(reference, privacy: .public) micLeadMs=\(micLeadMs, privacy: .public) appLeadMs=\(appLeadMs, privacy: .public) micFrames=\(micSamples.count, privacy: .public) appFrames=\(appSamples.count, privacy: .public)"
        )
        let micTimeline = SynchronizedAudioTimeline.reconstruct(
            samples: micSamples,
            segments: micSidecar.segments,
            referenceHostTimeNanos: reference,
            sampleRate: outputSampleRate
        )
        let appTimeline = SynchronizedAudioTimeline.reconstruct(
            samples: appSamples,
            segments: appSidecar.segments,
            referenceHostTimeNanos: reference,
            sampleRate: outputSampleRate
        )
        logger.info(
            "Timeline stereo. micSilence=\(micTimeline.insertedSilenceFrames, privacy: .public) micGaps=\(micTimeline.gapCount, privacy: .public) appSilence=\(appTimeline.insertedSilenceFrames, privacy: .public) appGaps=\(appTimeline.gapCount, privacy: .public)"
        )
        // Both timelines are anchored to the same reference (frame 0), so no residual offset.
        try writeStereoAAC(
            micSamples: micTimeline.frames,
            appSamples: appTimeline.frames,
            appOffsetSamples: 0,
            to: outputURL
        )
        return true
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
