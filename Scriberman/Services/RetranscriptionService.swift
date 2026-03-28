import Foundation
import SwiftData

actor RetranscriptionService {
    typealias ExtractSamples = @Sendable (URL, Bool) throws -> (mic: [Float], app: [Float]?)
    typealias PrepareModels = @Sendable (Workspace) async throws -> Void
    typealias TranscribePassFromSamples = @Sendable ([Float], AudioSource, Workspace) async throws -> [TranscriptSegment]
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
            try await transcriptionService.transcribePassFromSamples(samples: samples, source: source, workspace: workspace)
        }
        self.saveContext = saveContext ?? { context in
            try context.save()
        }
    }

    func retranscribe(session: any TranscribableSession, workspace: Workspace, context: ModelContext) async {
        var mixdownPath: String?
        var isStereo = false
        await MainActor.run {
            mixdownPath = session.mixdownURL
            isStereo = (session as? RecordingSession)?.appAudioURL != nil
            if mixdownPath == nil {
                session.status = .error("No mixdown available for retranscription")
                try? saveContext(context)
            } else {
                session.status = .retranscribing
                try? saveContext(context)
            }
        }
        guard let mixdownPath else {
            return
        }

        do {
            let mixdownURL = URL(fileURLWithPath: mixdownPath)
            let extracted = try extractSamples(mixdownURL, isStereo)
            try await prepareModelsHandler(workspace)

            async let micSegments = transcribePassFromSamplesHandler(extracted.mic, .mic, workspace)
            async let appSegments: [TranscriptSegment] = {
                guard let appSamples = extracted.app else { return [] }
                return try await transcribePassFromSamplesHandler(appSamples, .app, workspace)
            }()

            let merged = (try await (micSegments + appSegments)).sorted { $0.startTime < $1.startTime }
            let speakerIDs = Array(Set(merged.map(\.speakerId))).sorted()
            let speakers = speakerIDs.enumerated().map { index, speakerID in
                TranscriptSpeaker(
                    id: speakerID,
                    label: "Speaker \(index + 1)",
                    colorHex: transcriptAligner.speakerColorHex(at: index)
                )
            }

            await MainActor.run {
                session.retranscript = Transcript(
                    fullText: merged.map(\.text).joined(separator: " "),
                    segments: merged,
                    speakers: speakers
                )
                session.status = .done
                try? saveContext(context)
            }
        } catch {
            await MainActor.run {
                session.status = .error(error.localizedDescription)
                try? saveContext(context)
            }
        }
    }
}
