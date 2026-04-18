import SwiftData
import Foundation
import Testing
@testable import Scriberman

struct TranscriptionServiceTests {
    @Test
    func mergeByTimestampInterleavedInput() async {
        let service = TranscriptionService()
        let segments = [
            TranscriptSegment(speakerId: "S1", text: "later mic", startTime: 2.0, endTime: 2.3, audioSource: .mic),
            TranscriptSegment(speakerId: "app:S1", text: "earlier app", startTime: 0.8, endTime: 1.0, audioSource: .app),
            TranscriptSegment(speakerId: "S2", text: "middle mic", startTime: 1.4, endTime: 1.8, audioSource: .mic)
        ]

        let merged = await service.mergeByTimestamp(segments)
        #expect(merged.map(\.text) == ["earlier app", "middle mic", "later mic"])
    }

    @Test
    func mergeByTimestampMicOnlyInput() async {
        let service = TranscriptionService()
        let micSegments = [
            TranscriptSegment(speakerId: "S2", text: "second", startTime: 2.0, endTime: 2.2, audioSource: .mic),
            TranscriptSegment(speakerId: "S1", text: "first", startTime: 1.0, endTime: 1.2, audioSource: .mic)
        ]

        let merged = await service.mergeByTimestamp(micSegments)
        #expect(merged.map(\.text) == ["first", "second"])
        #expect(merged.allSatisfy { $0.audioSource == .mic })
    }

    @Test
    func mergeByTimestampWithEmptyAppInputReturnsMicSegmentsOnly() async {
        let service = TranscriptionService()
        let micSegments = [
            TranscriptSegment(speakerId: "S1", text: "only mic", startTime: 0.5, endTime: 0.9, audioSource: .mic)
        ]
        let allSegments = micSegments + [TranscriptSegment]()

        let merged = await service.mergeByTimestamp(allSegments)
        #expect(merged.count == 1)
        #expect(merged[0].text == "only mic")
        #expect(merged[0].audioSource == .mic)
    }

    @Test
    func transcribePassSilentAudioReturnsEmptySegments() async throws {
        let service = TranscriptionService(
            resampleAudioFile: { _ in [0, 0, 0, 0] },
            segmentSpeech: { _ in [] }
        )

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let audioURL = tempRoot.appendingPathComponent("silent.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data())
        let workspace = Workspace(rootURL: tempRoot)

        let (segments, embeddings) = try await service.transcribePassForTesting(url: audioURL, source: .app, workspace: workspace)
        #expect(segments == [])
        #expect(embeddings.isEmpty)
    }

    @Test
    func transcribePassFromSamplesSilentAudioReturnsEmptySegments() async throws {
        let service = TranscriptionService(
            resampleAudioFile: { _ in [1, 2, 3, 4] },
            segmentSpeech: { _ in [] }
        )
        let workspace = Workspace(rootURL: FileManager.default.temporaryDirectory)

        let (segments, embeddings) = try await service.transcribePassFromSamplesForTesting(
            samples: [0, 0, 0, 0],
            source: .mic,
            workspace: workspace
        )

        #expect(segments == [])
        #expect(embeddings.isEmpty)
    }

    @Test
    func transcribeThrowsMissingAudioWhenMixdownURLIsNil() async throws {
        let service = TranscriptionService()
        let workspace = Workspace(rootURL: FileManager.default.temporaryDirectory)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 3,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: nil,
            mixdownURL: nil,
            title: "Session",
            status: .recorded
        )
        let context = ModelContext(container)
        context.insert(session)
        try context.save()

        do {
            _ = try await service.transcribe(sessionID: session.id, modelContainer: container, workspace: workspace)
            Issue.record("Expected missing audio file error.")
            return
        } catch {
            guard case TranscriptionError.missingAudioFile = error else {
                Issue.record("Expected missingAudioFile, got \(error)")
                return
            }
        }
    }

    @Test
    func transcribeUsesM4AExtractionAndRunsMicAndAppPasses() async throws {
        let recorder = SampleRecorder()
        let service = TranscriptionService(
            resampleAudioFile: { _ in
                Issue.record("resampleAudioFile should not be used for M4A extraction path")
                return []
            },
            segmentSpeech: { samples in
                await recorder.record(samples)
                return []
            },
            extractSamples: { _, _ in
                (mic: [1.0, 2.0], app: [3.0, 4.0])
            },
            prepareModelsHandler: { _ in
                await recorder.markPrepared()
            }
        )

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 6,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: "/tmp/app.wav",
            mixdownURL: "/tmp/recording.m4a",
            title: "Session",
            status: .recorded
        )
        let context = ModelContext(container)
        context.insert(session)
        try context.save()
        let workspace = Workspace(rootURL: FileManager.default.temporaryDirectory)

        let transcript = try await service.transcribe(sessionID: session.id, modelContainer: container, workspace: workspace)

        #expect(transcript.segments.isEmpty)
        #expect(transcript.fullText.isEmpty)
        let captured = await recorder.captured
        #expect(captured.count == 2)
        #expect(captured.contains { $0 == [1.0, 2.0] })
        #expect(captured.contains { $0 == [3.0, 4.0] })
        let prepared = await recorder.prepared
        #expect(prepared)
    }

    @Test
    func prepareModelsSucceedsWhenThreeRequiredWorkspaceGroupsExist() async throws {
        let service = TranscriptionService()
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let workspace = Workspace(rootURL: tempRoot)
        let requiredGroups: [ModelGroup] = [.asrParakeetV3, .vadSilero, .offlineDiarization]
        for group in requiredGroups {
            let directory = workspace.modelsURL.appendingPathComponent(group.repoFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try await service.prepareModels(workspace: workspace)
    }

    @Test
    func prepareModelsThrowsMissingWorkspaceModelsWhenAnyRequiredGroupMissing() async throws {
        let service = TranscriptionService()
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let workspace = Workspace(rootURL: tempRoot)
        let presentGroups: [ModelGroup] = [.asrParakeetV3, .vadSilero]
        for group in presentGroups {
            let directory = workspace.modelsURL.appendingPathComponent(group.repoFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        do {
            try await service.prepareModels(workspace: workspace)
            Issue.record("Expected missingWorkspaceModels error.")
            return
        } catch let error as TranscriptionError {
            guard case .missingWorkspaceModels(let repos) = error else {
                Issue.record("Expected missingWorkspaceModels, got \(error)")
                return
            }
            #expect(repos.contains(ModelGroup.offlineDiarization.repoFolderName))
        }
    }
}

private actor SampleRecorder {
    private(set) var captured: [[Float]] = []
    private(set) var prepared: Bool = false

    func record(_ samples: [Float]) {
        captured.append(samples)
    }

    func markPrepared() {
        prepared = true
    }
}
