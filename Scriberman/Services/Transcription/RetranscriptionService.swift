import Foundation
import SwiftData

actor RetranscriptionService {
    typealias ExtractSamples = @Sendable (URL, Bool) throws -> (mic: [Float], app: [Float]?)
    typealias PrepareModels = @Sendable (Workspace) async throws -> Void
    typealias TranscribePassFromSamples = @Sendable ([Float], AudioSource, Workspace) async throws -> ([TranscriptSegment], [String: [Float]])
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
        self.transcribePassFromSamplesHandler = transcribePassFromSamplesHandler ?? { samples, source, workspace in
            let passRunner = await transcriptionService.makeTranscriptionPassRunner()
            return try await passRunner.run(samples: samples, source: source, workspace: workspace)
        }
        self.saveContext = saveContext ?? { context in
            try context.save()
        }
    }

    func retranscribe(sessionID: UUID, modelContainer: ModelContainer, workspace: Workspace) async {
        let context = ModelContext(modelContainer)
        
        var session: (any TranscribableSession)?

        let recordingDescriptor = FetchDescriptor<RecordingSession>()
        let importedDescriptor = FetchDescriptor<ImportedSession>()

        if let recording = try? context.fetch(recordingDescriptor).first(where: { $0.id == sessionID }) {
            session = recording
        } else if let imported = try? context.fetch(importedDescriptor).first(where: { $0.id == sessionID }) {
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

            async let micResult = transcribePassFromSamplesHandler(extracted.mic, .mic, workspace)
            async let appResult: ([TranscriptSegment], [String: [Float]]) = {
                guard let appSamples = extracted.app else { return ([], [:]) }
                return try await transcribePassFromSamplesHandler(appSamples, .app, workspace)
            }()

            let (micSegments, micEmbeddings) = try await micResult
            let (appSegments, appEmbeddings) = try await appResult
            
            let merged = (micSegments + appSegments).sorted { $0.startTime < $1.startTime }
            let mergedEmbeddings = micEmbeddings.merging(appEmbeddings) { (current, _) in current }

            let speakerIDs = Array(Set(merged.map(\.speakerId))).sorted()
            let speakers = speakerIDs.enumerated().map { index, speakerID in
                TranscriptSpeaker(
                    id: speakerID,
                    label: speakerID.hasPrefix("app:") || speakerID.hasPrefix("mic:") || speakerID.hasPrefix("unknown") ? "Speaker \(index + 1)" : speakerID,
                    colorHex: transcriptAligner.speakerColorHex(at: index)
                )
            }

            session.retranscript = Transcript(
                fullText: merged.map(\.text).joined(separator: " "),
                segments: merged,
                speakers: speakers,
                speakerEmbeddings: mergedEmbeddings
            )
            session.status = .done
            try? saveContext(context)
        } catch {
            session.status = .error(error.localizedDescription)
            try? saveContext(context)
        }
    }
}
