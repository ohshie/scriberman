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

    /// The rate every mixdown and import output is written at.
    static let outputSampleRate: Double = 48_000

    private let outputSampleRate = AudioMixdownService.outputSampleRate
    private let processingChunkSize: AVAudioFrameCount = 4_096
    private let fileManager = FileManager.default
    private let outputFormat: AudioMixdownOutputFormat
    private let removeItemAtURL: RemoveItemAtURL
    private let sampleReader: AudioSampleReader
    private let audioSyncConfig: AudioSyncConfig
    private let logger = Logger(subsystem: "Scriberman", category: "AudioMixdownService")

    init(
        outputFormat: AudioMixdownOutputFormat = .aacM4A,
        sampleReader: AudioSampleReader = AudioSampleReader(),
        audioSyncConfig: AudioSyncConfig = AudioSyncConfig(),
        removeItemAtURL: @escaping RemoveItemAtURL = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) {
        self.outputFormat = outputFormat
        self.sampleReader = sampleReader
        self.audioSyncConfig = audioSyncConfig
        self.removeItemAtURL = removeItemAtURL
    }

    /// `timelineMixdown` is the recording's own flag value; `nil` reads the stored flag, for
    /// imports and for recordings saved without a flag snapshot.
    func mix(
        micURL: URL,
        appURL: URL?,
        micStartHostTime: HostNanoseconds,
        appStartHostTime: HostNanoseconds?,
        into outputURL: URL,
        deleteSourceFiles: Bool = true,
        timelineMixdown: Bool? = nil
    ) async throws {
        logger.info(
            "Mix request received. mic=\(micURL.path, privacy: .public) app=\(appURL?.path ?? "nil", privacy: .public) out=\(outputURL.path, privacy: .public) format=\(String(describing: self.outputFormat), privacy: .public)"
        )
        logger.info(
            "Mix timing input. micStart=\(micStartHostTime, privacy: .public) appStart=\(appStartHostTime?.description ?? "0", privacy: .public)"
        )
        logger.info(
            "Input existence. micExists=\(self.fileManager.fileExists(atPath: micURL.path), privacy: .public) appExists=\(appURL.map { self.fileManager.fileExists(atPath: $0.path) } ?? false, privacy: .public)"
        )

        let micSamples = try await sampleReader.read(from: micURL, label: "mic")
        logger.info("Mic samples loaded. count=\(micSamples.count, privacy: .public)")

        if timelineMixdown ?? audioSyncConfig.isTimelineMixdownEnabled {
            if try await attemptTimelineMix(micURL: micURL, appURL: appURL, micSamples: micSamples, into: outputURL) {
                logger.notice("Used timeline (PTS-anchored) mixdown path.")
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
            logger.info("Computed legacy offsetSamples=\(offsetSamples, privacy: .public)")

            do {
                try writeMonoSummedAAC(
                    micSamples: micSamples,
                    appSamples: appSamples,
                    appOffsetSamples: offsetSamples,
                    to: outputURL
                )
                logger.info("Mono-summed write completed to \(outputURL.path, privacy: .public)")
            } catch {
                logger.error("Mono-summed write failed: \(error.localizedDescription, privacy: .public)")
                throw RecordingError.failedToStart("Mixdown mono-summed write failed: \(error.localizedDescription)")
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
        // Assertion, not a routine precondition. Timing segments are recorded inside the write, so
        // a segment exists only for frames the file has; these totals should now always agree. A
        // mismatch means the capture-time invariant broke somewhere new, and this warning is the
        // only signal of it — so it stays, and stays loud.
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
            logger.notice("Timeline mono. silenceFrames=\(micTimeline.insertedSilenceFrames, privacy: .public) gaps=\(micTimeline.gapCount, privacy: .public) overlap=\(micTimeline.overlapFrames, privacy: .public)")
            try writeMonoAAC(samples: micTimeline.frames, to: outputURL)
            return true
        }

        guard let appSidecar = AudioFileStreamer.loadTimingSidecar(for: appURL),
              let appFirstSegment = appSidecar.segments.first else {
            return false
        }
        let appSamples = try await sampleReader.read(from: appURL, label: "app")
        // See the mic guard above: this is an assertion on the capture-time invariant.
        guard appSidecar.totalFrames == appSamples.count else {
            logger.warning(
                "App timing frames (\(appSidecar.totalFrames, privacy: .public)) != decoded samples (\(appSamples.count, privacy: .public)); cannot trust timeline."
            )
            return false
        }

        let reference = min(micFirstSegment.startHostTimeNanos, appFirstSegment.startHostTimeNanos)
        let micLeadMs = Double(micFirstSegment.startHostTimeNanos - reference) / 1_000_000.0
        let appLeadMs = Double(appFirstSegment.startHostTimeNanos - reference) / 1_000_000.0
        logger.notice(
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
        logger.notice(
            "Timeline mic + app. micSilence=\(micTimeline.insertedSilenceFrames, privacy: .public) micGaps=\(micTimeline.gapCount, privacy: .public) appSilence=\(appTimeline.insertedSilenceFrames, privacy: .public) appGaps=\(appTimeline.gapCount, privacy: .public) micOverlap=\(micTimeline.overlapFrames, privacy: .public) appOverlap=\(appTimeline.overlapFrames, privacy: .public)"
        )
        // Both timelines are anchored to the same reference (frame 0), so no residual offset.
        try writeMonoSummedAAC(
            micSamples: micTimeline.frames,
            appSamples: appTimeline.frames,
            appOffsetSamples: 0,
            to: outputURL
        )
        return true
    }

    func computeOffsetSamples(
        micStartHostTime: HostNanoseconds,
        appStartHostTime: HostNanoseconds?
    ) -> Int {
        guard let appStartHostTime else {
            return 0
        }

        return Int((appStartHostTime.seconds(since: micStartHostTime) * outputSampleRate).rounded())
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

    /// Writes mic and app as one channel on their aligned positions. A positive offset starts the
    /// app source later, a negative one starts the mic later; the output is as long as the longer
    /// aligned source.
    private func writeMonoSummedAAC(
        micSamples: [Float],
        appSamples: [Float],
        appOffsetSamples: Int,
        to outputURL: URL
    ) throws {
        let micStartFrame = max(0, -appOffsetSamples)
        let appStartFrame = max(0, appOffsetSamples)
        let totalFrames = max(micStartFrame + micSamples.count, appStartFrame + appSamples.count)

        var summed = [Float](repeating: 0, count: totalFrames)
        for (index, sample) in micSamples.enumerated() {
            summed[micStartFrame + index] = sample
        }
        for (index, sample) in appSamples.enumerated() {
            summed[appStartFrame + index] += sample
        }

        let reducedFrames = Self.applyLookAheadLimiter(to: &summed, sampleRate: outputSampleRate)
        try writeMonoAAC(samples: summed, to: outputURL)
        logger.notice(
            "Mixdown written mono-summed. frames=\(totalFrames, privacy: .public) micStartFrame=\(micStartFrame, privacy: .public) appStartFrame=\(appStartFrame, privacy: .public) limiterReducedFrames=\(reducedFrames, privacy: .public)"
        )
    }

    /// −1 dBFS as a linear amplitude.
    private static let limiterCeiling = Float(pow(10.0, -1.0 / 20.0))

    /// Look-ahead gain limiter. A frame above the ceiling needs gain `ceiling / |sample|`; the gain
    /// ramps linearly from 1 down to that value over the ~5 ms before the frame and recovers
    /// linearly to 1 over ~50 ms after it. A frame with no over-ceiling frame in its look-ahead
    /// window and no release in progress keeps gain 1, so it is unchanged. Returns the number of
    /// frames whose gain was below 1.
    private static func applyLookAheadLimiter(to samples: inout [Float], sampleRate: Double) -> Int {
        let ceiling = limiterCeiling
        let lookAheadFrames = max(1, Int((sampleRate * 0.005).rounded()))
        let releaseStep = Float(1.0 / (sampleRate * 0.050))

        // Attack gain for the frames from the one being output to the newest one read, keyed by
        // frame index modulo the window size.
        let windowSize = lookAheadFrames + 1
        var attackGains = [Float](repeating: 1, count: windowSize)
        var gain: Float = 1
        var reducedFrames = 0

        for newest in 0..<(samples.count + lookAheadFrames) {
            if newest < samples.count {
                let magnitude = abs(samples[newest])
                if magnitude > ceiling {
                    let required = ceiling / magnitude
                    for distance in 0...lookAheadFrames where newest - distance >= 0 {
                        let ramped = required + (1 - required) * Float(distance) / Float(lookAheadFrames)
                        let slot = (newest - distance) % windowSize
                        attackGains[slot] = min(attackGains[slot], ramped)
                    }
                }
            }

            let frame = newest - lookAheadFrames
            guard frame >= 0 else { continue }
            let slot = frame % windowSize
            gain = min(attackGains[slot], gain + releaseStep, 1)
            attackGains[slot] = 1

            guard gain < 1 else { continue }
            reducedFrames += 1
            let limited = samples[frame] * gain
            // Guards against the product rounding a hair above the ceiling.
            samples[frame] = max(-ceiling, min(ceiling, limited))
        }
        return reducedFrames
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
