import Foundation
import OSLog
import SwiftData

actor RetranscriptionService {
    typealias ExtractSamples = @Sendable (URL) throws -> (mic: [Float], app: [Float]?)
    typealias PrepareModels = @Sendable (Workspace) async throws -> Void
    typealias TranscribePassFromSamples = @Sendable ([Float], AudioSource, Workspace, LiveTranscriptionPipelineSettings, TranscriptionPassRunner.SharedPassEngines?) async throws -> TranscriptionPassRunner.PassResult
    typealias SaveContext = @Sendable (ModelContext) throws -> Void

    private let transcriptionService: TranscriptionService
    private let extractSamples: ExtractSamples
    private let prepareModelsHandler: PrepareModels
    private let transcribePassFromSamplesHandler: TranscribePassFromSamples
    private let saveContext: SaveContext
    private let sessionJobs: SessionJobs
    private let transcriptAligner = TranscriptAligner()
    private let logger = Logger(subsystem: "Scriberman", category: "RetranscriptionService")

    init(
        transcriptionService: TranscriptionService,
        extractSamples: ExtractSamples? = nil,
        prepareModelsHandler: PrepareModels? = nil,
        transcribePassFromSamplesHandler: TranscribePassFromSamples? = nil,
        saveContext: SaveContext? = nil,
        sessionJobs: SessionJobs = SessionJobs()
    ) {
        self.transcriptionService = transcriptionService
        self.extractSamples = extractSamples ?? { url in
            try M4AChannelExtractor().extract(url: url)
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
        self.sessionJobs = sessionJobs
    }

    func retranscribe(
        sessionID: UUID,
        modelContainer: ModelContainer,
        workspace: Workspace,
        pipelineSettings: LiveTranscriptionPipelineSettings = .defaults
    ) async {
        // In a task of its own, so a delete of the session cancels it and waits for it.
        await sessionJobs.run(sessionID) { generation in
            await self.retranscribe(
                sessionID: sessionID,
                modelContainer: modelContainer,
                workspace: workspace,
                pipelineSettings: pipelineSettings,
                generation: generation
            )
        }
    }

    /// Saves a new transcript pass, unless the session is deleted first. Cancellation stops the
    /// passes between chunks; the sample extraction and each model call are waited out.
    private func retranscribe(
        sessionID: UUID,
        modelContainer: ModelContainer,
        workspace: Workspace,
        pipelineSettings: LiveTranscriptionPipelineSettings,
        generation: SessionJobs.Generation
    ) async {
        guard sessionJobs.mayWrite(generation) else {
            logger.notice("Retranscription for session \(sessionID, privacy: .public) not started: the session was deleted.")
            return
        }
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

        let mixdownPath = session.mixdownURL
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
            let extracted = try extractSamples(mixdownURL)
            try Task.checkCancellation()
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

            var retranscript = Transcript(
                fullText: Transcript.fullText(joining: merged),
                segments: merged,
                speakers: speakers,
                speakerEmbeddings: mergedEmbeddings,
                voiceprintSpace: VoiceprintSpace.current
            )
            if extracted.app == nil, (session as? RecordingSession)?.appAudioURL != nil {
                retranscript.isSinglePassOfMixedAudio = true
            }
            guard sessionJobs.mayWrite(generation) else {
                logger.notice("Retranscript for session \(sessionID, privacy: .public) not saved: the session was deleted.")
                return
            }
            session.retranscript = retranscript
            session.status = .done
            try? saveContext(context)
            if let recording = session as? RecordingSession {
                rewriteTranscriptMarkdown(for: recording)
            }
        } catch {
            guard sessionJobs.mayWrite(generation) else {
                logger.notice("Retranscription for session \(sessionID, privacy: .public) stopped: the session was deleted.")
                return
            }
            session.status = .error(error.localizedDescription)
            try? saveContext(context)
        }
    }
}
