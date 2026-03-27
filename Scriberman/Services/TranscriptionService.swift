import FluidAudio
import Foundation

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
    private let fileManager = FileManager.default
    private let transcriptAligner = TranscriptAligner()

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

    func transcribe(audioURL: URL, workspace: Workspace) async throws -> Transcript {
        try await prepareModels(workspace: workspace)

        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw TranscriptionError.missingAudioFile
        }

        let samples: [Float]
        do {
            samples = try AudioConverter().resampleAudioFile(audioURL)
        } catch {
            throw TranscriptionError.failedToTranscribe(error.localizedDescription)
        }

        let asrResult: ASRResult
        do {
            let asrManager = AsrManager(config: .default)
            let asrModels = try await AsrModels.downloadAndLoad()
            try await asrManager.initialize(models: asrModels)
            asrResult = try await asrManager.transcribe(samples, source: .system)
        } catch {
            throw TranscriptionError.failedToTranscribe(error.localizedDescription)
        }

        let diarizationResult: DiarizationResult
        do {
            let diarizerManager = DiarizerManager(config: .default)
            let diarizerModels = try await DiarizerModels.downloadIfNeeded()
            diarizerManager.initialize(models: diarizerModels)
            diarizationResult = try diarizerManager.performCompleteDiarization(samples, sampleRate: 16_000)
        } catch {
            throw TranscriptionError.failedToTranscribe(error.localizedDescription)
        }

        return transcriptAligner.alignTranscript(
            fullText: asrResult.text,
            tokenTimings: asrResult.tokenTimings ?? [],
            diarizedSegments: diarizationResult.segments
        )
    }
}
