import FluidAudio
import Foundation
import OSLog
import SwiftData

private func defaultSegmentSpeech(_ samples: [Float]) async throws -> [VadSegment] {
    let vadManager = try await VadManager(config: VadConfig(defaultThreshold: 0.75))
    return try await vadManager.segmentSpeech(samples, config: VadSegmentationConfig.default)
}

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
    typealias ExtractSamples = (URL, Bool) throws -> (mic: [Float], app: [Float]?)
    typealias PrepareModelsHandler = (Workspace) async throws -> Void

    private let fileManager = FileManager.default
    private let transcriptAligner = TranscriptAligner()
    private let logger = Logger(subsystem: "Scriberman", category: "TranscriptionService")
    private let resampleAudioFile: ResampleAudioFile
    private let segmentSpeech: SegmentSpeech
    private let extractSamples: ExtractSamples
    private let prepareModelsHandler: PrepareModelsHandler?
    private let speakerEmbeddingStore: SpeakerEmbeddingStore?
    private let minimumChunkSamples = 16_000
    private let modelPathResolver = ModelPathResolver()

    init(
        speakerEmbeddingStore: SpeakerEmbeddingStore? = nil,
        resampleAudioFile: @escaping ResampleAudioFile = { url in
            try AudioConverter().resampleAudioFile(url)
        },
        segmentSpeech: @escaping SegmentSpeech = defaultSegmentSpeech,
        extractSamples: @escaping ExtractSamples = { url, isStereo in
            try M4AChannelExtractor().extract(url: url, isStereo: isStereo)
        },
        prepareModelsHandler: PrepareModelsHandler? = nil
    ) {
        self.speakerEmbeddingStore = speakerEmbeddingStore
        self.resampleAudioFile = resampleAudioFile
        self.segmentSpeech = segmentSpeech
        self.extractSamples = extractSamples
        self.prepareModelsHandler = prepareModelsHandler
    }

    func prepareModels(workspace: Workspace) async throws {
        let requiredGroups: [ModelGroup] = [.asrParakeetV3, .vadSilero, .offlineDiarization]
        var missingRepos: [String] = []

        for group in requiredGroups {
            do {
                _ = try modelPathResolver.modelDirectory(for: group, in: workspace)
            } catch TranscriptionError.missingWorkspaceModels(let repos) {
                missingRepos.append(contentsOf: repos)
            } catch {
                missingRepos.append(group.repoFolderName)
            }
        }

        if !missingRepos.isEmpty {
            throw TranscriptionError.missingWorkspaceModels(missingRepos)
        }
    }

    func mergeByTimestamp(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.sorted { $0.startTime < $1.startTime }
    }

    func transcribe(sessionID: UUID, modelContainer: ModelContainer, workspace: Workspace) async throws -> Transcript {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<RecordingSession>()
        let sessions = try context.fetch(descriptor)
        var session: RecordingSession?
        for candidate in sessions where candidate.id == sessionID {
            session = candidate
            break
        }

        guard let session else {
            throw TranscriptionError.failedToTranscribe("Session not found for ID \(sessionID)")
        }

        logger.info("Starting transcription for session \(session.id, privacy: .public)")
        guard let mixdownPath = session.mixdownURL else {
            throw TranscriptionError.missingAudioFile
        }
        let mixdownURL = URL(fileURLWithPath: mixdownPath)
        if let prepareModelsHandler {
            try await prepareModelsHandler(workspace)
        } else {
            try await prepareModels(workspace: workspace)
        }

        let extractedSamples: (mic: [Float], app: [Float]?)
        do {
            extractedSamples = try extractSamples(mixdownURL, session.appAudioURL != nil)
        } catch {
            throw TranscriptionError.failedToTranscribe("M4A extraction failed - \(error.localizedDescription)")
        }

        async let micResult = transcribePassFromSamples(
            samples: extractedSamples.mic,
            source: .mic,
            workspace: workspace
        )
        async let appResult: ([TranscriptSegment], [String: [Float]]) = {
            guard let appSamples = extractedSamples.app else { return ([], [:]) }
            return try await transcribePassFromSamples(
                samples: appSamples,
                source: .app,
                workspace: workspace
            )
        }()

        let (micSegments, micEmbeddings) = try await micResult
        let (appSegments, appEmbeddings) = try await appResult
        
        let mergedSegments = mergeByTimestamp(micSegments + appSegments)
        let mergedEmbeddings = micEmbeddings.merging(appEmbeddings) { (current, _) in current }

        logger.info("Completed transcription for session \(session.id, privacy: .public) with \(mergedSegments.count, privacy: .public) segments")
        let speakerIds = Array(Set(mergedSegments.map(\.speakerId))).sorted()
        let speakers = speakerIds.enumerated().map { index, speakerId in
            TranscriptSpeaker(
                id: speakerId,
                label: speakerId.hasPrefix("app:") || speakerId.hasPrefix("mic:") || speakerId.hasPrefix("unknown") ? "Speaker \(index + 1)" : speakerId,
                colorHex: transcriptAligner.speakerColorHex(at: index)
            )
        }

        return Transcript(
            fullText: mergedSegments.map(\.text).joined(separator: " "),
            segments: mergedSegments,
            speakers: speakers,
            speakerEmbeddings: mergedEmbeddings
        )
    }

    private func transcribePass(
        url: URL,
        source: AudioSource,
        workspace: Workspace
    ) async throws -> ([TranscriptSegment], [String: [Float]]) {
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

        return try await transcribePassFromSamples(samples: samples, source: source, workspace: workspace)
    }

    func transcribePassFromSamples(
        samples: [Float],
        source: AudioSource,
        workspace: Workspace
    ) async throws -> ([TranscriptSegment], [String: [Float]]) {
        let passRunner = makeTranscriptionPassRunner()
        return try await passRunner.run(
            samples: samples,
            source: source,
            workspace: workspace
        )
    }

    func transcribePassForTesting(
        url: URL,
        source: AudioSource,
        workspace: Workspace
    ) async throws -> ([TranscriptSegment], [String: [Float]]) {
        try await transcribePass(url: url, source: source, workspace: workspace)
    }

    func transcribePassFromSamplesForTesting(
        samples: [Float],
        source: AudioSource,
        workspace: Workspace
    ) async throws -> ([TranscriptSegment], [String: [Float]]) {
        try await transcribePassFromSamples(samples: samples, source: source, workspace: workspace)
    }

    internal func matchSpeakers(diarizationResult: DiarizationResult) async throws -> [String: String] {
        let passRunner = makeTranscriptionPassRunner()
        return try await passRunner.matchSpeakers(diarizationResult: diarizationResult)
    }

    func makeTranscriptionPassRunner() -> TranscriptionPassRunner {
        let segmentSpeech = self.segmentSpeech
        return TranscriptionPassRunner(
            speakerEmbeddingStore: speakerEmbeddingStore,
            minimumChunkSamples: minimumChunkSamples,
            segmentSpeech: { samples in
                let vadSegments = try await segmentSpeech(samples)
                return vadSegments.map { segment in
                    TranscriptionPassRunner.SpeechSegment(
                        startTime: segment.startTime,
                        endTime: segment.endTime
                    )
                }
            }
        )
    }
}
