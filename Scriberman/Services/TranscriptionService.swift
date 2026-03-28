import FluidAudio
import Foundation
import OSLog

enum TranscriptionError: LocalizedError {
    case missingAudioFile
    case missingWorkspaceModels([String])
    case failedToPrepareModels(String)
    case failedToTranscribe(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioFile:
            return "Audio file not found"
        case .missingWorkspaceModels(let repos):
            return "Missing required models in workspace: \(repos.joined(separator: ", "))"
        case .failedToPrepareModels(let reason):
            return "Failed to prepare models: \(reason)"
        case .failedToTranscribe(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}

actor TranscriptionService: TranscriptionServiceProtocol {
    typealias ResampleAudioFile = (URL) throws -> [Float]
    typealias SegmentSpeech = ([Float]) async throws -> [VadSegment]

    private let fileManager = FileManager.default
    private let transcriptAligner = TranscriptAligner()
    private let logger = Logger(subsystem: "Scriberman", category: "TranscriptionService")
    private let resampleAudioFile: ResampleAudioFile
    private let segmentSpeech: SegmentSpeech
    private let minimumChunkSamples = 16_000

    init(
        resampleAudioFile: @escaping ResampleAudioFile = { url in
            try AudioConverter().resampleAudioFile(url)
        },
        segmentSpeech: @escaping SegmentSpeech = { samples in
            let vadManager = try await VadManager(config: VadConfig(defaultThreshold: 0.75))
            return try await vadManager.segmentSpeech(samples, config: VadSegmentationConfig.default)
        }
    ) {
        self.resampleAudioFile = resampleAudioFile
        self.segmentSpeech = segmentSpeech
    }

    func prepareModels(workspace: Workspace) async throws {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let appSupport else {
            throw TranscriptionError.failedToPrepareModels("Application Support path is unavailable.")
        }

        let cacheRoot = appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)

        let requiredGroups: [ModelGroup] = [.asrParakeetV3, .vadSilero, .diarization]
        var missingRepos: [String] = []

        for group in requiredGroups {
            let sourceURL = workspace.modelsURL.appendingPathComponent(group.repoFolderName, isDirectory: true)
            var isDirectory: ObjCBool = false
            let sourceExists = fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)
            if !sourceExists || !isDirectory.boolValue {
                missingRepos.append(group.repoFolderName)
                continue
            }

            let destinationURL = cacheRoot.appendingPathComponent(group.repoFolderName, isDirectory: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                continue
            }

            do {
                try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                throw TranscriptionError.failedToPrepareModels(error.localizedDescription)
            }
        }

        if !missingRepos.isEmpty {
            throw TranscriptionError.missingWorkspaceModels(missingRepos)
        }
    }

    func mergeByTimestamp(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.sorted { $0.startTime < $1.startTime }
    }

    func transcribe(session: RecordingSession, workspace: Workspace) async throws -> Transcript {
        logger.info("Starting transcription for session \(session.id, privacy: .public)")
        try await prepareModels(workspace: workspace)

        let micURL = URL(fileURLWithPath: session.micAudioURL)
        guard fileManager.fileExists(atPath: micURL.path) else {
            throw TranscriptionError.missingAudioFile
        }

        let appURL = session.appAudioURL.map(URL.init(fileURLWithPath:))

        async let micSegments = transcribePass(url: micURL, source: .mic, workspace: workspace)
        async let appSegments: [TranscriptSegment] = {
            guard let appURL else { return [] }
            return try await transcribePass(url: appURL, source: .app, workspace: workspace)
        }()

        let mergedSegments = try await mergeByTimestamp(micSegments + appSegments)
        logger.info("Completed transcription for session \(session.id, privacy: .public) with \(mergedSegments.count, privacy: .public) segments")
        let speakerIds = Array(Set(mergedSegments.map(\.speakerId))).sorted()
        let speakers = speakerIds.enumerated().map { index, speakerId in
            TranscriptSpeaker(
                id: speakerId,
                label: "Speaker \(index + 1)",
                colorHex: transcriptAligner.speakerColorHex(at: index)
            )
        }

        return Transcript(
            fullText: mergedSegments.map(\.text).joined(separator: " "),
            segments: mergedSegments,
            speakers: speakers
        )
    }

    private func transcribePass(
        url: URL,
        source: AudioSource,
        workspace: Workspace
    ) async throws -> [TranscriptSegment] {
        _ = workspace
        let passName = source == .app ? "app" : "mic"
        logger.info("Starting \(passName, privacy: .public) pass for file \(url.lastPathComponent, privacy: .public)")
        guard fileManager.fileExists(atPath: url.path) else {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: audio file not found at \(url.path)")
        }

        let samples: [Float]
        do {
            samples = try resampleAudioFile(url)
        } catch {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: resample failed - \(error.localizedDescription)")
        }

        let speechSegments: [VadSegment]
        do {
            speechSegments = try await segmentSpeech(samples)
        } catch {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: VAD failed - \(error.localizedDescription)")
        }

        guard !speechSegments.isEmpty else {
            logger.info("\(passName, privacy: .public) pass produced no speech segments")
            return []
        }

        let asrManager = AsrManager(config: .default)
        let diarizerManager = DiarizerManager(config: .default)
        do {
            let asrModels = try await AsrModels.downloadAndLoad()
            try await asrManager.initialize(models: asrModels)
            let diarizerModels = try await DiarizerModels.downloadIfNeeded()
            diarizerManager.initialize(models: diarizerModels)
        } catch {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: model initialization failed - \(error.localizedDescription)")
        }

        var allSegments: [TranscriptSegment] = []
        for speechSegment in speechSegments {
            let startIndex = max(0, Int(speechSegment.startTime * 16_000.0))
            let endIndex = min(samples.count, max(startIndex + 1, Int(speechSegment.endTime * 16_000.0)))
            guard startIndex < endIndex else {
                continue
            }

            var chunkSamples = Array(samples[startIndex..<endIndex])
            if chunkSamples.count < minimumChunkSamples {
                let missing = minimumChunkSamples - chunkSamples.count
                chunkSamples.append(contentsOf: Array(repeating: 0, count: missing))
                logger.info("Padded \(passName, privacy: .public) chunk from \(chunkSamples.count - missing, privacy: .public) to \(chunkSamples.count, privacy: .public) samples")
            }

            let asrResult: ASRResult
            let diarizationResult: DiarizationResult
            do {
                asrResult = try await asrManager.transcribe(chunkSamples, source: .system)
                diarizationResult = try diarizerManager.performCompleteDiarization(chunkSamples, sampleRate: 16_000)
            } catch {
                throw TranscriptionError.failedToTranscribe("\(passName) pass: ASR/diarization failed - \(error.localizedDescription)")
            }

            let aligned = transcriptAligner.alignTranscript(
                fullText: asrResult.text,
                tokenTimings: asrResult.tokenTimings ?? [],
                diarizedSegments: diarizationResult.segments,
                source: source
            )

            let adjusted: [TranscriptSegment] = aligned.segments.map { segment in
                let speakerId: String
                if source == .app {
                    speakerId = segment.speakerId.hasPrefix("app:") ? segment.speakerId : "app:\(segment.speakerId)"
                } else {
                    speakerId = segment.speakerId
                }
                return TranscriptSegment(
                    speakerId: speakerId,
                    text: segment.text,
                    startTime: segment.startTime + Float(speechSegment.startTime),
                    endTime: segment.endTime + Float(speechSegment.startTime),
                    audioSource: source
                )
            }

            allSegments.append(contentsOf: adjusted)
        }

        return allSegments
    }

    func transcribePassForTesting(
        url: URL,
        source: AudioSource,
        workspace: Workspace
    ) async throws -> [TranscriptSegment] {
        try await transcribePass(url: url, source: source, workspace: workspace)
    }
}
