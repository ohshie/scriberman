import FluidAudio
import Foundation
import OSLog
import SwiftData

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

    init(
        speakerEmbeddingStore: SpeakerEmbeddingStore? = nil,
        resampleAudioFile: @escaping ResampleAudioFile = { url in
            try AudioConverter().resampleAudioFile(url)
        },
        segmentSpeech: @escaping SegmentSpeech = { samples in
            let vadManager = try await VadManager(config: VadConfig(defaultThreshold: 0.75))
            return try await vadManager.segmentSpeech(samples, config: VadSegmentationConfig.default)
        },
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
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let appSupport else {
            throw TranscriptionError.failedToPrepareModels("Application Support path is unavailable.")
        }

        let cacheRoot = appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)

        let requiredGroups: [ModelGroup] = [.asrParakeetV3, .vadSilero, .offlineDiarization]
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

    func transcribe(sessionID: UUID, modelContainer: ModelContainer, workspace: Workspace) async throws -> Transcript {
        let context = ModelContext(modelContainer)
        let predicate = #Predicate<RecordingSession> { $0.id == sessionID }
        var descriptor = FetchDescriptor<RecordingSession>(predicate: predicate)
        descriptor.fetchLimit = 1
        
        guard let session = try? context.fetch(descriptor).first else {
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
        
        let mergedSegments = try await mergeByTimestamp(micSegments + appSegments)
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
        _ = workspace
        let passName = source == .app ? "app" : "mic"
        let speechSegments: [VadSegment]
        do {
            speechSegments = try await segmentSpeech(samples)
        } catch {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: VAD failed - \(error.localizedDescription)")
        }

        guard !speechSegments.isEmpty else {
            logger.info("\(passName, privacy: .public) pass produced no speech segments")
            return ([], [:])
        }

        let asrManager = AsrManager(config: .default)
        let offlineDiarizerManager = OfflineDiarizerManager(config: .default)
        do {
            let asrModels = try await AsrModels.downloadAndLoad()
            try await asrManager.initialize(models: asrModels)
            
            let diarizerModels = try await OfflineDiarizerModels.load(from: workspace.modelsURL)
            offlineDiarizerManager.initialize(models: diarizerModels)
        } catch {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: model initialization failed - \(error.localizedDescription)")
        }

        var asrSegments: [TranscriptSegment] = []
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
            }

            let asrResult: ASRResult
            do {
                asrResult = try await asrManager.transcribe(chunkSamples, source: .system)
            } catch {
                throw TranscriptionError.failedToTranscribe("\(passName) pass: ASR failed - \(error.localizedDescription)")
            }

            // Map ASR result tokens to segments with global timestamps
            let tokens = asrResult.tokenTimings ?? []
            if !tokens.isEmpty {
                // For simplicity in this refactor, we'll create a single segment per VAD chunk for now
                // but aligned with global timestamps. 
                // In a full implementation, we might split by words.
                let segment = TranscriptSegment(
                    speakerId: "unknown",
                    text: asrResult.text,
                    startTime: Float(speechSegment.startTime),
                    endTime: Float(speechSegment.endTime),
                    audioSource: source
                )
                asrSegments.append(segment)
            }
        }

        // Global Offline Diarization
        let diarizationResult: DiarizationResult
        do {
            diarizationResult = try await offlineDiarizerManager.process(audio: samples)
        } catch {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: Offline diarization failed - \(error.localizedDescription)")
        }

        // Speaker Matching logic for Task 2.3
        var speakerMapping: [String: String] = [:] // Map local ID to Profile Name
        if let store = speakerEmbeddingStore {
            if let db = diarizationResult.speakerDatabase {
                for (clusterId, embedding) in db {
                    // Try to find a match in the store
                    let profiles = try? await store.fetchAll()
                    var bestMatch: SpeakerProfile?
                    var bestSimilarity: Float = Float.greatestFiniteMagnitude

                    for profile in profiles ?? [] {
                        let distance = SpeakerUtilities.cosineDistance(embedding, profile.embedding)
                        if distance < bestSimilarity && distance < 0.28 { 
                            bestSimilarity = distance
                            bestMatch = profile
                        }
                    }

                    if let match = bestMatch {
                        speakerMapping[clusterId] = match.name
                        try? await store.updateProfile(id: match.id)
                    }
                }
            }
        }

        // Align ASR segments with global diarization
        let alignedSegments = transcriptAligner.alignTranscript(
            fullText: asrSegments.map(\.text).joined(separator: " "),
            tokenTimings: [], // We already have coarse segments
            diarizedSegments: diarizationResult.segments,
            source: source
        )

        // Adjust speaker IDs for app source and apply global speaker names
        let finalSegments = alignedSegments.segments.map { segment in
            let baseId = segment.speakerId
            let mappedName = speakerMapping[baseId]
            let finalSpeakerId = mappedName ?? baseId

            let speakerId: String
            if source == .app {
                speakerId = finalSpeakerId.hasPrefix("app:") ? finalSpeakerId : "app:\(finalSpeakerId)"
            } else {
                speakerId = finalSpeakerId
            }
            return TranscriptSegment(
                speakerId: speakerId,
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime,
                audioSource: source
            )
        }

        // Map embeddings to final speaker IDs
        var finalEmbeddings: [String: [Float]] = [:]
        if let db = diarizationResult.speakerDatabase {
            for (baseId, embedding) in db {
                let mappedName = speakerMapping[baseId]
                let finalSpeakerId = mappedName ?? baseId
                
                let speakerId: String
                if source == .app {
                    speakerId = finalSpeakerId.hasPrefix("app:") ? finalSpeakerId : "app:\(finalSpeakerId)"
                } else {
                    speakerId = finalSpeakerId
                }
                finalEmbeddings[speakerId] = embedding
            }
        }

        return (finalSegments, finalEmbeddings)
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
        var speakerMapping: [String: String] = [:] // Map local ID to Profile Name
        guard let store = speakerEmbeddingStore, let db = diarizationResult.speakerDatabase else {
            return [:]
        }

        let threshold: Float = 0.28
        let profiles = (try? await store.fetchAll()) ?? []

        for (clusterId, embedding) in db {
            var bestMatch: SpeakerProfile?
            var bestDistance = threshold

            for profile in profiles {
                let distance = SpeakerUtilities.cosineDistance(embedding, profile.embedding)
                if distance < bestDistance {
                    bestDistance = distance
                    bestMatch = profile
                } else if distance == bestDistance && bestMatch != nil {
                    // Tie-breaker: prefer earlier seen profile if distance is identical
                    if profile.lastSeen < (bestMatch?.lastSeen ?? .distantFuture) {
                        bestMatch = profile
                    }
                }
            }

            if let match = bestMatch {
                speakerMapping[clusterId] = match.name
                try? await store.updateProfile(id: match.id)
            }
        }
        return speakerMapping
    }
}
