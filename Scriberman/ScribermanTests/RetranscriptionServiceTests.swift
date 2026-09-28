import Testing
import SwiftData
import Foundation
@testable import Scriberman

@Suite("RetranscriptionService Tests")
@MainActor
struct RetranscriptionServiceTests {
    private final class LockedValue<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T

        init(_ value: T) {
            self.value = value
        }

        func set(_ newValue: T) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> T {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let container: ModelContainer
    private let context: ModelContext

    private func fetchRecordingSession(id: UUID, in modelContainer: ModelContainer) throws -> RecordingSession? {
        let verifyContext = ModelContext(modelContainer)
        return try verifyContext.fetch(FetchDescriptor<RecordingSession>()).first(where: { $0.id == id })
    }

    private func fetchImportedSession(id: UUID, in modelContainer: ModelContainer) throws -> ImportedSession? {
        let verifyContext = ModelContext(modelContainer)
        return try verifyContext.fetch(FetchDescriptor<ImportedSession>()).first(where: { $0.id == id })
    }

    init() throws {
        self.container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        self.context = ModelContext(container)
    }

    // MARK: - Speaker labels

    private func retranscriptLabels(
        profiles: [(name: String, embedding: [Float])],
        mic: OfflineLabelFixture.Cluster,
        app: OfflineLabelFixture.Cluster?
    ) async throws -> [String: String] {
        let store = try await OfflineLabelFixture.store(profiles: profiles)
        let service = RetranscriptionService(
            transcriptionService: OfflineLabelFixture.transcriptionService(store: store, mic: mic, app: app),
            extractSamples: OfflineLabelFixture.extractSamples(hasApp: app != nil),
            prepareModelsHandler: { _ in }
        )
        let (container, sessionID) = try OfflineLabelFixture.sessionContainer(hasApp: app != nil)
        await service.retranscribe(sessionID: sessionID, modelContainer: container, workspace: OfflineLabelFixture.workspace)
        let retranscript = try #require(try fetchRecordingSession(id: sessionID, in: container)?.retranscript)
        return Dictionary(uniqueKeysWithValues: retranscript.speakers.map { ($0.id, $0.label) })
    }

    @Test("Recognized app speaker keeps the profile name after retranscription")
    func retranscriptLabelsRecognizedAppSpeaker() async throws {
        let labels = try await retranscriptLabels(
            profiles: [("Alice", OfflineLabelFixture.voice(0))],
            mic: .init(id: "S1", embedding: OfflineLabelFixture.voice(5)),
            app: .init(id: "S1", embedding: OfflineLabelFixture.voice(0))
        )
        #expect(labels["app:Alice"] == "Alice")
    }

    @Test("Unmatched mic speaker is labelled Speaker N after retranscription")
    func retranscriptLabelsUnmatchedMicSpeaker() async throws {
        let labels = try await retranscriptLabels(
            profiles: [],
            mic: .init(id: "S1", embedding: OfflineLabelFixture.voice(5)),
            app: nil
        )
        #expect(labels == ["S1": "Speaker 1"])
    }

    @Test("Recognized profile named like a cluster keeps its name after retranscription")
    func retranscriptLabelsProfileNamedLikeACluster() async throws {
        let labels = try await retranscriptLabels(
            profiles: [("S1", OfflineLabelFixture.voice(0))],
            mic: .init(id: "S7", embedding: OfflineLabelFixture.voice(0)),
            app: nil
        )
        #expect(labels == ["S1": "S1"])
    }

    @Test("Unmatched app speaker is labelled Speaker N after retranscription")
    func retranscriptLabelsUnmatchedAppSpeaker() async throws {
        let labels = try await retranscriptLabels(
            profiles: [("Alice", OfflineLabelFixture.voice(0))],
            mic: .init(id: "S1", embedding: OfflineLabelFixture.voice(0)),
            app: .init(id: "S1", embedding: OfflineLabelFixture.voice(5))
        )
        #expect(labels == ["Alice": "Alice", "app:S1": "Speaker 2"])
    }

    @Test("Same profile on both channels after retranscription")
    func retranscriptLabelsSameProfileOnBothChannels() async throws {
        let labels = try await retranscriptLabels(
            profiles: [("Alice", OfflineLabelFixture.voice(0))],
            mic: .init(id: "S1", embedding: OfflineLabelFixture.voice(0)),
            app: .init(id: "S1", embedding: OfflineLabelFixture.voice(0))
        )
        #expect(labels == ["Alice": "Alice", "app:Alice": "Alice"])
    }

    @Test("Stereo retranscription success stores retranscript and sets done status")
    func retranscribeStereoSuccess() async throws {
        let transcriptionService = TranscriptionService()
        let service = RetranscriptionService(
            transcriptionService: transcriptionService,
            extractSamples: { _, _ in
                (mic: [0.1, 0.2], app: [0.3, 0.4])
            },
            prepareModelsHandler: { _ in },
            transcribePassFromSamplesHandler: { _, source, _, _, _ in
                switch source {
                case .mic:
                    return TranscriptionPassRunner.PassResult(segments: [
                        TranscriptSegment(
                            speakerId: "S1",
                            text: "mic line",
                            startTime: 2.0,
                            endTime: 2.2,
                            audioSource: .mic
                        )
                    ])
                case .app:
                    return TranscriptionPassRunner.PassResult(segments: [
                        TranscriptSegment(
                            speakerId: "app:S1",
                            text: "app line",
                            startTime: 1.0,
                            endTime: 1.2,
                            audioSource: .app
                        )
                    ])
                }
            }
        )

        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 12,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: "/tmp/app.wav",
            mixdownURL: "/tmp/recording.m4a",
            title: "Session",
            status: .done
        )
        session.transcript = Transcript(
            fullText: "original",
            segments: [
                TranscriptSegment(
                    speakerId: "S0",
                    text: "original",
                    startTime: 0,
                    endTime: 0.5,
                    audioSource: .mic
                )
            ],
            speakers: [TranscriptSpeaker(id: "S0", label: "Speaker 1", colorHex: "#111111")]
        )

        let sessionID = session.id
        context.insert(session)
        try context.save()

        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        await service.retranscribe(sessionID: sessionID, modelContainer: container, workspace: workspace)

        let fetched = try fetchRecordingSession(id: sessionID, in: container)
        #expect(fetched?.status == .done)
        #expect(fetched?.retranscript?.segments.map(\.text) == ["app line", "mic line"])
        #expect(fetched?.transcript?.fullText == "original")
    }

    @Test("Mono retranscription success stores mic-only retranscript")
    func retranscribeMonoSuccess() async throws {
        let transcriptionService = TranscriptionService()
        let service = RetranscriptionService(
            transcriptionService: transcriptionService,
            extractSamples: { _, _ in
                (mic: [0.1, 0.2], app: nil)
            },
            prepareModelsHandler: { _ in },
            transcribePassFromSamplesHandler: { _, source, _, _, _ in
                #expect(source == .mic)
                return TranscriptionPassRunner.PassResult(segments: [
                    TranscriptSegment(
                        speakerId: "S1",
                        text: "mic only",
                        startTime: 0.0,
                        endTime: 0.5,
                        audioSource: .mic
                    )
                ])
            }
        )

        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 8,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: nil,
            mixdownURL: "/tmp/recording.m4a",
            title: "Session",
            status: .done
        )

        let sessionID = session.id
        context.insert(session)
        try context.save()

        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        await service.retranscribe(sessionID: sessionID, modelContainer: container, workspace: workspace)

        let fetched = try fetchRecordingSession(id: sessionID, in: container)
        #expect(fetched?.status == .done)
        #expect(fetched?.retranscript?.segments.count == 1)
        #expect(fetched?.retranscript?.segments.first?.audioSource == .mic)
    }

    @Test("Retranscription with nil mixdown sets error status")
    func retranscribeWithNilMixdown() async throws {
        let service = RetranscriptionService(transcriptionService: TranscriptionService())
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 5,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: nil,
            mixdownURL: nil,
            title: "Session",
            status: .done
        )

        let sessionID = session.id
        context.insert(session)
        try context.save()

        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        await service.retranscribe(sessionID: sessionID, modelContainer: container, workspace: workspace)

        let fetched = try fetchRecordingSession(id: sessionID, in: container)
        #expect(fetched?.status == .error("No mixdown available for retranscription"))
        #expect(fetched?.retranscript == nil)
    }

    @Test("Extraction failure during retranscription sets error status")
    func retranscribeExtractionFailure() async throws {
        enum ForcedError: LocalizedError {
            case extraction
            var errorDescription: String? { "Forced extraction failure" }
        }

        let transcriptionService = TranscriptionService()
        let service = RetranscriptionService(
            transcriptionService: transcriptionService,
            extractSamples: { _, _ in
                throw ForcedError.extraction
            },
            prepareModelsHandler: { _ in
                Issue.record("prepareModels should not be called when extraction fails")
            },
            transcribePassFromSamplesHandler: { _, _, _, _, _ in
                Issue.record("transcribePassFromSamples should not be called when extraction fails")
                return TranscriptionPassRunner.PassResult()
            }
        )

        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 6,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: nil,
            mixdownURL: "/tmp/recording.m4a",
            title: "Session",
            status: .done
        )

        let sessionID = session.id
        context.insert(session)
        try context.save()

        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        await service.retranscribe(sessionID: sessionID, modelContainer: container, workspace: workspace)

        let fetched = try fetchRecordingSession(id: sessionID, in: container)
        if case .error(let message) = fetched?.status {
            #expect(message == "Forced extraction failure")
        } else {
            Issue.record("Expected error status")
        }
        #expect(fetched?.retranscript == nil)
    }

    @Test("Imported session retranscription uses mono extraction")
    func retranscribeImportedSession() async throws {
        let transcriptionService = TranscriptionService()
        let capturedIsStereo = LockedValue<Bool?>(nil)
        let service = RetranscriptionService(
            transcriptionService: transcriptionService,
            extractSamples: { _, isStereo in
                capturedIsStereo.set(isStereo)
                return (mic: [0.1, 0.2], app: nil)
            },
            prepareModelsHandler: { _ in },
            transcribePassFromSamplesHandler: { _, source, _, _, _ in
                #expect(source == .mic)
                return TranscriptionPassRunner.PassResult(segments: [
                    TranscriptSegment(
                        speakerId: "S1",
                        text: "imported",
                        startTime: 0.0,
                        endTime: 0.5,
                        audioSource: .mic
                    )
                ])
            }
        )

        let session = ImportedSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 8,
            mixdownURL: "/tmp/recording.m4a",
            title: "Imported",
            originalFileName: "sample.mp3",
            originalFormat: "mp3",
            status: .done
        )
        let sessionID = session.id
        context.insert(session)
        try context.save()

        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        await service.retranscribe(sessionID: sessionID, modelContainer: container, workspace: workspace)

        #expect(capturedIsStereo.get() == false)
        let fetched = try fetchImportedSession(id: sessionID, in: container)
        #expect(fetched?.status == .done)
        #expect(fetched?.retranscript?.segments.first?.text == "imported")
    }
}
