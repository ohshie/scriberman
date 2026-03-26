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

actor TranscriptionService {
    private let fileManager = FileManager.default

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

        return alignTranscript(
            fullText: asrResult.text,
            tokenTimings: asrResult.tokenTimings ?? [],
            diarizedSegments: diarizationResult.segments
        )
    }

    private func alignTranscript(
        fullText: String,
        tokenTimings: [TokenTiming],
        diarizedSegments: [TimedSpeakerSegment]
    ) -> Transcript {
        let cleanedWords = tokenTimings.compactMap { timing -> TimedWord? in
            let tokenPiece = normalizeTokenPiece(timing.token)
            guard !tokenPiece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TimedWord(text: tokenPiece, start: Float(timing.startTime), end: Float(timing.endTime))
        }

        let sortedDiarized = diarizedSegments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        let mappedSegments: [TranscriptSegment]

        if !cleanedWords.isEmpty {
            mappedSegments = sortedDiarized.compactMap { segment in
                let words = cleanedWords
                    .filter {
                        $0.end > segment.startTimeSeconds && $0.start < segment.endTimeSeconds
                    }
                let text = stitchTokens(words.map(\.text))
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    speakerId: segment.speakerId,
                    text: text,
                    startTime: segment.startTimeSeconds,
                    endTime: segment.endTimeSeconds
                )
            }
        } else {
            if sortedDiarized.isEmpty {
                mappedSegments = fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? []
                    : [
                        TranscriptSegment(
                            speakerId: "S1",
                            text: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
                            startTime: 0,
                            endTime: Float(max(0, fullText.count / 12))
                        )
                    ]
            } else {
                let trimmedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                mappedSegments = trimmedText.isEmpty
                    ? []
                    : [
                        TranscriptSegment(
                            speakerId: sortedDiarized[0].speakerId,
                            text: trimmedText,
                            startTime: sortedDiarized[0].startTimeSeconds,
                            endTime: sortedDiarized.last?.endTimeSeconds ?? sortedDiarized[0].endTimeSeconds
                        )
                    ]
            }
        }

        let speakerIds = Array(Set(mappedSegments.map(\.speakerId))).sorted()
        let speakers = speakerIds.enumerated().map { index, speakerId in
            TranscriptSpeaker(
                id: speakerId,
                label: "Speaker \(index + 1)",
                colorHex: speakerColorHex(at: index)
            )
        }

        let normalizedFullText: String
        if mappedSegments.isEmpty {
            normalizedFullText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            normalizedFullText = mappedSegments.map(\.text).joined(separator: " ")
        }

        return Transcript(
            fullText: normalizedFullText,
            segments: mappedSegments,
            speakers: speakers
        )
    }

    private func normalizeTokenPiece(_ token: String) -> String {
        token.replacingOccurrences(of: "▁", with: " ")
    }

    private func stitchTokens(_ tokens: [String]) -> String {
        var text = tokens.joined()
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?<=\\p{L})\\s+'\\s*(?=\\p{L})", with: "'", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func speakerColorHex(at index: Int) -> String {
        let palette = ["#4F46E5", "#16A34A", "#EA580C", "#0891B2", "#DC2626", "#7C3AED"]
        return palette[index % palette.count]
    }
}

private struct TimedWord {
    let text: String
    let start: Float
    let end: Float
}
