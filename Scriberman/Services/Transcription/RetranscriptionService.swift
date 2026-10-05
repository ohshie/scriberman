import Foundation
import SwiftData

actor RetranscriptionService {
    typealias ExtractSamples = @Sendable (URL, Bool) throws -> (mic: [Float], app: [Float]?)
    typealias PrepareModels = @Sendable (Workspace) async throws -> Void
    typealias TranscribePassFromSamples = @Sendable ([Float], AudioSource, Workspace, LiveTranscriptionPipelineSettings, TranscriptionPassRunner.SharedPassEngines?) async throws -> TranscriptionPassRunner.PassResult
    typealias SaveContext = @Sendable (ModelContext) throws -> Void

    private let transcriptionService: TranscriptionService
    private let extractSamples: ExtractSamples
    private let prepareModelsHandler: PrepareModels
    private let transcribePassFromSamplesHandler: TranscribePassFromSamples
    private let saveContext: SaveContext
    private let transcriptAligner = TranscriptAligner()

    init(
        transcriptionService: TranscriptionService,
        extractSamples: ExtractSamples? = nil,
        prepareModelsHandler: PrepareModels? = nil,
        transcribePassFromSamplesHandler: TranscribePassFromSamples? = nil,
        saveContext: SaveContext? = nil
    ) {
        self.transcriptionService = transcriptionService
        self.extractSamples = extractSamples ?? { url, isStereo in
            try M4AChannelExtractor().extract(url: url, isStereo: isStereo)
        }
        self.prepareModelsHandler = prepareModelsHandler ?? { workspace in
            try await transcriptionService.prepareModels(workspace: workspace)
        }
        self.transcribePassFromSamplesHandler = transcribePassFromSamplesHandler ?? { samples, source, workspace, pipelineSettings, engines in
            try await transcriptionService.transcribePassFromSamples(
                samples: samples,
                source: source,
                workspace: workspace,
                pipelineSettings: pipelineSettings,
                engines: engines
            )
        }
        self.saveContext = saveContext ?? { context in
            try context.save()
        }
    }

    func retranscribe(
        sessionID: UUID,
        modelContainer: ModelContainer,
        workspace: Workspace,
        pipelineSettings: LiveTranscriptionPipelineSettings = .defaults
    ) async {
        let context = ModelContext(modelContainer)
        
        var session: (any TranscribableSession)?

        if let recording = try? RecordingSession.fetch(id: sessionID, in: context) {
            session = recording
        }
        if session == nil, let imported = try? ImportedSession.fetch(id: sessionID, in: context) {
            session = imported
        }
        
        guard let session = session else {
            return
        }

        var mixdownPath: String?
        var isStereo = false
        
        mixdownPath = session.mixdownURL
        isStereo = (session as? RecordingSession)?.appAudioURL != nil
        if mixdownPath == nil {
            session.status = .error("No mixdown available for retranscription")
            try? saveContext(context)
        } else {
            session.status = .retranscribing
            try? saveContext(context)
        }

        guard let mixdownPath else {
            return
        }

        do {
            let mixdownURL = URL(fileURLWithPath: mixdownPath)
            let extracted = try extractSamples(mixdownURL, isStereo)
            try await prepareModelsHandler(workspace)

            let sharedEngines = await transcriptionService.makeSharedPassEngines()
            async let micResult = transcribePassFromSamplesHandler(extracted.mic, .mic, workspace, pipelineSettings, sharedEngines)
            async let appResult: TranscriptionPassRunner.PassResult = {
                guard let appSamples = extracted.app else { return TranscriptionPassRunner.PassResult() }
                return try await transcribePassFromSamplesHandler(appSamples, .app, workspace, pipelineSettings, sharedEngines)
            }()

            let mic = try await micResult
            let app = try await appResult

            let merged = (mic.segments + app.segments).sorted { $0.startTime < $1.startTime }
            let mergedEmbeddings = mic.speakerEmbeddings.merging(app.speakerEmbeddings) { (current, _) in current }

            let speakers = TranscriptionService.offlineSpeakers(
                for: merged.map(\.speakerId),
                matched: mic.matchedSpeakerIDs.merging(app.matchedSpeakerIDs) { current, _ in current },
                colorHex: transcriptAligner.speakerColorHex(at:)
            )

            session.retranscript = Transcript(
                fullText: Transcript.fullText(joining: merged),
                segments: merged,
                speakers: speakers,
                speakerEmbeddings: mergedEmbeddings,
                voiceprintSpace: VoiceprintSpace.current
            )
            session.status = .done
            try? saveContext(context)
            if let recording = session as? RecordingSession {
                rewriteTranscriptMarkdown(for: recording)
            }
        } catch {
            session.status = .error(error.localizedDescription)
            try? saveContext(context)
        }
    }
}
