import FluidAudio
import Foundation

struct TranscriptionPassRunner {
    struct SpeechSegment {
        let startTime: Double
        let endTime: Double
    }

    struct PassASRResult {
        let text: String
        let tokenTimings: [TokenTiming]
    }

    struct PassDiarizationResult {
        let segments: [TimedSpeakerSegment]
        let speakerDatabase: [String: [Float]]?
    }

    struct PassEngines {
        let transcribeChunk: ([Float], AudioSource) async throws -> PassASRResult
        let diarize: ([Float]) async throws -> PassDiarizationResult
    }

    typealias SegmentSpeech = ([Float]) async throws -> [SpeechSegment]
    typealias MakePassEngines = (Workspace) async throws -> PassEngines
    typealias AlignTranscript = (String, [TokenTiming], [TimedSpeakerSegment], AudioSource) -> Transcript

    private let speakerEmbeddingStore: SpeakerEmbeddingStore?
    private let minimumChunkSamples: Int
    private let segmentSpeech: SegmentSpeech
    private let makePassEngines: MakePassEngines
    private let alignTranscript: AlignTranscript

    init(
        speakerEmbeddingStore: SpeakerEmbeddingStore? = nil,
        minimumChunkSamples: Int = 16_000,
        segmentSpeech: @escaping SegmentSpeech = { samples in
            let vadManager = try await VadManager(config: VadConfig(defaultThreshold: 0.75))
            let segments = try await vadManager.segmentSpeech(samples, config: VadSegmentationConfig.default)
            return segments.map { segment in
                SpeechSegment(startTime: segment.startTime, endTime: segment.endTime)
            }
        },
        makePassEngines: MakePassEngines? = nil,
        alignTranscript: AlignTranscript? = nil
    ) {
        self.speakerEmbeddingStore = speakerEmbeddingStore
        self.minimumChunkSamples = minimumChunkSamples
        self.segmentSpeech = segmentSpeech
        self.makePassEngines = makePassEngines ?? Self.defaultMakePassEngines(modelPathResolver: ModelPathResolver())
        let transcriptAligner = TranscriptAligner()
        self.alignTranscript = alignTranscript ?? { fullText, tokenTimings, diarizedSegments, source in
            transcriptAligner.alignTranscript(
                fullText: fullText,
                tokenTimings: tokenTimings,
                diarizedSegments: diarizedSegments,
                source: source
            )
        }
    }

    func run(samples: [Float], source: AudioSource, workspace: Workspace) async throws -> ([TranscriptSegment], [String: [Float]]) {
        let passName = source == .app ? "app" : "mic"
        let speechSegments: [SpeechSegment]
        do {
            speechSegments = try await segmentSpeech(samples)
        } catch {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: VAD failed - \(error.localizedDescription)")
        }

        guard !speechSegments.isEmpty else {
            return ([], [:])
        }

        let passEngines: PassEngines
        do {
            passEngines = try await makePassEngines(workspace)
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: model initialization failed - \(error.localizedDescription)")
        }

        var globalTokenTimings: [TokenTiming] = []
        var allASRTexts: [String] = []
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

            let asrResult: PassASRResult
            do {
                asrResult = try await passEngines.transcribeChunk(chunkSamples, source)
            } catch {
                throw TranscriptionError.failedToTranscribe("\(passName) pass: ASR failed - \(error.localizedDescription)")
            }

            let trimmedText = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                allASRTexts.append(trimmedText)
            }

            let offsetTimings = asrResult.tokenTimings.map { timing in
                TokenTiming(
                    token: timing.token,
                    tokenId: timing.tokenId,
                    startTime: timing.startTime + speechSegment.startTime,
                    endTime: timing.endTime + speechSegment.startTime,
                    confidence: timing.confidence
                )
            }
            globalTokenTimings.append(contentsOf: offsetTimings)
        }

        let fullASRText = allASRTexts.joined(separator: " ")

        let diarizationResult: PassDiarizationResult
        do {
            diarizationResult = try await passEngines.diarize(samples)
        } catch {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: Offline diarization failed - \(error.localizedDescription)")
        }

        let speakerMapping = try await matchSpeakers(speakerDatabase: diarizationResult.speakerDatabase)

        let alignedTranscript = alignTranscript(
            fullASRText,
            globalTokenTimings,
            diarizationResult.segments,
            source
        )

        let finalSegments = alignedTranscript.segments.map { segment in
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

    func matchSpeakers(diarizationResult: DiarizationResult) async throws -> [String: String] {
        try await matchSpeakers(speakerDatabase: diarizationResult.speakerDatabase)
    }

    private func matchSpeakers(speakerDatabase: [String: [Float]]?) async throws -> [String: String] {
        var speakerMapping: [String: String] = [:]
        guard let store = speakerEmbeddingStore, let db = speakerDatabase else {
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

    private static func defaultMakePassEngines(modelPathResolver: ModelPathResolver) -> MakePassEngines {
        { workspace in
            let asrManager = AsrManager(config: .default)
            let offlineDiarizerManager = OfflineDiarizerManager(config: .default)

            let asrModelDirectory = try modelPathResolver.modelDirectory(for: .asrParakeetV3, in: workspace)
            let asrModels = try await AsrModels.load(from: asrModelDirectory)
            try await asrManager.initialize(models: asrModels)

            let diarizerModels = try await OfflineDiarizerModels.load(from: workspace.modelsURL)
            offlineDiarizerManager.initialize(models: diarizerModels)

            return PassEngines(
                transcribeChunk: { chunkSamples, _ in
                    let result = try await asrManager.transcribe(chunkSamples, source: .system)
                    return PassASRResult(
                        text: result.text,
                        tokenTimings: result.tokenTimings ?? []
                    )
                },
                diarize: { inputSamples in
                    let result = try await offlineDiarizerManager.process(audio: inputSamples)
                    return PassDiarizationResult(
                        segments: result.segments,
                        speakerDatabase: result.speakerDatabase
                    )
                }
            )
        }
    }
}
