import SwiftData
import XCTest
@testable import Scriberman

@MainActor
final class RetranscriptionServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: RecordingSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    func testRetranscribeStereoSuccessStoresRetranscriptAndSetsDone() async {
        let transcriptionService = TranscriptionService()
        let service = RetranscriptionService(
            transcriptionService: transcriptionService,
            extractSamples: { _, _ in
                (mic: [0.1, 0.2], app: [0.3, 0.4])
            },
            prepareModelsHandler: { _ in },
            transcribePassFromSamplesHandler: { _, source, _ in
                switch source {
                case .mic:
                    return [
                        TranscriptSegment(
                            speakerId: "S1",
                            text: "mic line",
                            startTime: 2.0,
                            endTime: 2.2,
                            audioSource: .mic
                        )
                    ]
                case .app:
                    return [
                        TranscriptSegment(
                            speakerId: "app:S1",
                            text: "app line",
                            startTime: 1.0,
                            endTime: 1.2,
                            audioSource: .app
                        )
                    ]
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

        context.insert(session)
        try? context.save()

        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        await service.retranscribe(session: session, workspace: workspace, context: context)

        XCTAssertEqual(session.status, .done)
        XCTAssertEqual(session.retranscript?.segments.map(\.text), ["app line", "mic line"])
        XCTAssertEqual(session.transcript?.fullText, "original")
    }

    func testRetranscribeMonoSuccessStoresMicOnlyRetranscript() async {
        let transcriptionService = TranscriptionService()
        let service = RetranscriptionService(
            transcriptionService: transcriptionService,
            extractSamples: { _, _ in
                (mic: [0.1, 0.2], app: nil)
            },
            prepareModelsHandler: { _ in },
            transcribePassFromSamplesHandler: { _, source, _ in
                XCTAssertEqual(source, .mic)
                return [
                    TranscriptSegment(
                        speakerId: "S1",
                        text: "mic only",
                        startTime: 0.0,
                        endTime: 0.5,
                        audioSource: .mic
                    )
                ]
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

        context.insert(session)
        try? context.save()

        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        await service.retranscribe(session: session, workspace: workspace, context: context)

        XCTAssertEqual(session.status, .done)
        XCTAssertEqual(session.retranscript?.segments.count, 1)
        XCTAssertEqual(session.retranscript?.segments.first?.audioSource, .mic)
    }

    func testRetranscribeWithNilMixdownSetsExpectedError() async {
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

        context.insert(session)
        try? context.save()

        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        await service.retranscribe(session: session, workspace: workspace, context: context)

        XCTAssertEqual(session.status, .error("No mixdown available for retranscription"))
        XCTAssertNil(session.retranscript)
    }

    func testRetranscribeExtractionFailureSetsErrorStatus() async {
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
                XCTFail("prepareModels should not be called when extraction fails")
            },
            transcribePassFromSamplesHandler: { _, _, _ in
                XCTFail("transcribePassFromSamples should not be called when extraction fails")
                return []
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

        context.insert(session)
        try? context.save()

        let workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        await service.retranscribe(session: session, workspace: workspace, context: context)

        if case .error(let message) = session.status {
            XCTAssertEqual(message, "Forced extraction failure")
        } else {
            XCTFail("Expected error status")
        }
        XCTAssertNil(session.retranscript)
    }
}
