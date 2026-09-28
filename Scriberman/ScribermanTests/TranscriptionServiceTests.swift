import FluidAudio
import SwiftData
import Foundation
import Testing
@testable import Scriberman

struct TranscriptionServiceTests {
    // MARK: - Speaker labels

    private func labels(
        profiles: [(name: String, embedding: [Float])],
        mic: OfflineLabelFixture.Cluster,
        app: OfflineLabelFixture.Cluster?
    ) async throws -> [String: String] {
        let store = try await OfflineLabelFixture.store(profiles: profiles)
        let service = OfflineLabelFixture.transcriptionService(store: store, mic: mic, app: app)
        let (container, sessionID) = try OfflineLabelFixture.sessionContainer(hasApp: app != nil)
        let transcript = try await service.transcribe(
            sessionID: sessionID,
            modelContainer: container,
            workspace: OfflineLabelFixture.workspace
        )
        return Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0.label) })
    }

    @Test
    func recognizedAppSpeakerIsLabelledWithProfileName() async throws {
        let labels = try await labels(
            profiles: [("Alice", OfflineLabelFixture.voice(0))],
            mic: .init(id: "S1", embedding: OfflineLabelFixture.voice(5)),
            app: .init(id: "S1", embedding: OfflineLabelFixture.voice(0))
        )
        #expect(labels["app:Alice"] == "Alice")
    }

    @Test
    func unmatchedMicSpeakerIsLabelledSpeakerN() async throws {
        let labels = try await labels(
            profiles: [],
            mic: .init(id: "S1", embedding: OfflineLabelFixture.voice(5)),
            app: nil
        )
        #expect(labels == ["S1": "Speaker 1"])
    }

    @Test
    func recognizedProfileNamedLikeAClusterKeepsItsName() async throws {
        let labels = try await labels(
            profiles: [("S1", OfflineLabelFixture.voice(0))],
            mic: .init(id: "S7", embedding: OfflineLabelFixture.voice(0)),
            app: nil
        )
        #expect(labels == ["S1": "S1"])
    }

    @Test
    func unmatchedAppSpeakerIsLabelledSpeakerN() async throws {
        let labels = try await labels(
            profiles: [("Alice", OfflineLabelFixture.voice(0))],
            mic: .init(id: "S1", embedding: OfflineLabelFixture.voice(0)),
            app: .init(id: "S1", embedding: OfflineLabelFixture.voice(5))
        )
        #expect(labels == ["Alice": "Alice", "app:S1": "Speaker 2"])
    }

    @Test
    func sameProfileOnBothChannelsGivesTwoSpeakersWithOneName() async throws {
        let labels = try await labels(
            profiles: [("Alice", OfflineLabelFixture.voice(0))],
            mic: .init(id: "S1", embedding: OfflineLabelFixture.voice(0)),
            app: .init(id: "S1", embedding: OfflineLabelFixture.voice(0))
        )
        #expect(labels == ["Alice": "Alice", "app:Alice": "Alice"])
    }

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

        let passResult = try await service.transcribePassForTesting(url: audioURL, source: .app, workspace: workspace)
        let segments = passResult.segments
        let embeddings = passResult.speakerEmbeddings
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

        let passResult = try await service.transcribePassFromSamplesForTesting(
            samples: [0, 0, 0, 0],
            source: .mic,
            workspace: workspace
        )
        let segments = passResult.segments
        let embeddings = passResult.speakerEmbeddings

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
        let requiredGroups: [ModelGroup] = [.asrParakeetUltra, .vadSilero, .offlineDiarization]
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
        let presentGroups: [ModelGroup] = [.asrParakeetUltra, .vadSilero]
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

/// Offline passes in which the mic and app channels each hear one speaker cluster, run through
/// the real pass runner and speaker matching, for speaker-label tests.
enum OfflineLabelFixture {
    struct Cluster: Sendable {
        let id: String
        let embedding: [Float]
    }

    static let workspace = Workspace(rootURL: FileManager.default.temporaryDirectory)
    private static let micSample: Float = 0.1
    private static let appSample: Float = 0.2

    /// A unit vector along `axis`; distinct axes are orthogonal voices.
    static func voice(_ axis: Int) -> [Float] {
        (0..<192).map { $0 == axis ? Float(1) : Float(0) }
    }

    static func store(profiles: [(name: String, embedding: [Float])]) async throws -> SpeakerEmbeddingStore {
        let container = try ModelContainer(
            for: SpeakerProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = SpeakerEmbeddingStore(modelContainer: container)
        for profile in profiles {
            try await store.enrollNamedSpeaker(name: profile.name, embedding: profile.embedding)
        }
        return store
    }

    static func extractSamples(hasApp: Bool) -> @Sendable (URL, Bool) throws -> (mic: [Float], app: [Float]?) {
        { _, _ in
            (
                mic: Array(repeating: micSample, count: 16_000),
                app: hasApp ? Array(repeating: appSample, count: 16_000) : nil
            )
        }
    }

    static func transcriptionService(store: SpeakerEmbeddingStore, mic: Cluster, app: Cluster?) -> TranscriptionService {
        TranscriptionService(
            speakerEmbeddingStore: store,
            segmentSpeech: { _ in [VadSegment(startTime: 0, endTime: 1)] },
            extractSamples: extractSamples(hasApp: app != nil),
            prepareModelsHandler: { _ in },
            makePassEngines: { _ in
                TranscriptionPassRunner.PassEngines(
                    transcribeChunk: { _, _ in
                        TranscriptionPassRunner.PassASRResult(
                            text: "hello",
                            tokenTimings: [TokenTiming(token: " hello", tokenId: 1, startTime: 0, endTime: 0.5, confidence: 1)]
                        )
                    },
                    diarize: { samples in
                        let cluster = samples.first == appSample ? (app ?? mic) : mic
                        return TranscriptionPassRunner.PassDiarizationResult(
                            segments: [TimedSpeakerSegment(
                                speakerId: cluster.id,
                                embedding: [],
                                startTimeSeconds: 0,
                                endTimeSeconds: 1,
                                qualityScore: 1
                            )],
                            speakerDatabase: [cluster.id: cluster.embedding]
                        )
                    }
                )
            }
        )
    }

    /// An in-memory store holding one recorded session with a mixdown, stereo when `hasApp`.
    static func sessionContainer(hasApp: Bool) throws -> (ModelContainer, UUID) {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 1,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: hasApp ? "/tmp/app.wav" : nil,
            mixdownURL: "/tmp/recording.m4a",
            title: "Session",
            status: .recorded
        )
        let context = ModelContext(container)
        context.insert(session)
        try context.save()
        return (container, session.id)
    }
}
