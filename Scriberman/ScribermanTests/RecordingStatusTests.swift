import XCTest
@testable import Scriberman

final class RecordingStatusTests: XCTestCase {
    func testNonErrorStatusesRoundTripPersistence() {
        let statuses: [RecordingStatus] = [.recorded, .converting, .transcribing, .retranscribing, .done]

        for status in statuses {
            let reconstructed = RecordingStatus(persistedValue: status.persistedValue, errorMessage: nil)
            XCTAssertEqual(reconstructed, status)
        }
    }

    func testErrorStatusRoundTripsWithMessage() {
        let status = RecordingStatus.error("something went wrong")
        let reconstructed = RecordingStatus(
            persistedValue: status.persistedValue,
            errorMessage: "something went wrong"
        )

        XCTAssertEqual(reconstructed, .error("something went wrong"))
    }

    func testUnknownPersistedValueFallsBackToRecorded() {
        XCTAssertEqual(
            RecordingStatus(persistedValue: "unknown", errorMessage: nil),
            .recorded
        )
    }

    func testRecordingSessionStoresCapturedAppNameWhenProvided() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/audio.wav",
            title: "Session",
            capturedAppName: "Zoom",
            status: .recorded
        )

        XCTAssertEqual(session.capturedAppName, "Zoom")
    }

    func testRecordingSessionCapturedAppNameDefaultsToNil() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/audio.wav",
            title: "Session",
            status: .recorded
        )

        XCTAssertNil(session.capturedAppName)
    }

    func testRecordingSessionStoresAppAudioURLWhenProvided() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: "/tmp/app.wav",
            title: "Session",
            status: .recorded
        )

        XCTAssertEqual(session.micAudioURL, "/tmp/mic.wav")
        XCTAssertEqual(session.appAudioURL, "/tmp/app.wav")
    }

    func testRecordingSessionAppAudioURLDefaultsToNil() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            title: "Session",
            status: .recorded
        )

        XCTAssertEqual(session.micAudioURL, "/tmp/mic.wav")
        XCTAssertNil(session.appAudioURL)
    }

    func testRecordingSessionStoresMixdownURLWhenProvided() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            mixdownURL: "/tmp/recording.m4a",
            title: "Session",
            status: .recorded
        )

        XCTAssertEqual(session.mixdownURL, "/tmp/recording.m4a")
    }

    func testRecordingSessionMixdownURLDefaultsToNil() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            title: "Session",
            status: .recorded
        )

        XCTAssertNil(session.mixdownURL)
    }

    func testRecordingSessionRetranscriptRoundTripsWithoutAffectingOriginalTranscript() {
        let original = Transcript(
            fullText: "original",
            segments: [
                TranscriptSegment(
                    speakerId: "S1",
                    text: "original",
                    startTime: 0,
                    endTime: 1,
                    audioSource: .mic
                )
            ],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")]
        )
        let retranscript = Transcript(
            fullText: "retry",
            segments: [
                TranscriptSegment(
                    speakerId: "S2",
                    text: "retry",
                    startTime: 0,
                    endTime: 1,
                    audioSource: .mic
                )
            ],
            speakers: [TranscriptSpeaker(id: "S2", label: "Speaker 2", colorHex: "#222222")]
        )
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            title: "Session",
            status: .recorded
        )

        session.transcript = original
        session.retranscript = retranscript

        XCTAssertEqual(session.transcript?.fullText, "original")
        XCTAssertEqual(session.retranscript?.fullText, "retry")
        XCTAssertNotNil(session.transcriptData)
        XCTAssertNotNil(session.retranscriptData)
    }

    @MainActor
    func testTranscriptDetailViewModelPrefersRetranscript() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: "/tmp/app.wav",
            mixdownURL: "/tmp/recording.m4a",
            title: "Session",
            status: .done
        )
        session.transcript = Transcript(
            fullText: "original",
            segments: [TranscriptSegment(speakerId: "S1", text: "original", startTime: 0, endTime: 1, audioSource: .mic)],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker", colorHex: "#111111")]
        )
        session.retranscript = Transcript(
            fullText: "retry",
            segments: [TranscriptSegment(speakerId: "app:S1", text: "retry", startTime: 0, endTime: 1, audioSource: .app)],
            speakers: [TranscriptSpeaker(id: "app:S1", label: "Speaker", colorHex: "#222222")]
        )

        let viewModel = TranscriptDetailViewModel(session: session, aiProviderService: makeAIProviderService())
        XCTAssertEqual(viewModel.displayedTranscript?.fullText, "retry")
        XCTAssertEqual(viewModel.finalTranscriptText, "retry")
        XCTAssertEqual(viewModel.originalTranscriptText, "original")
        XCTAssertTrue(viewModel.isReprocessed)
    }

    @MainActor
    func testTranscriptDetailViewModelApplicationNameAndReprocessedFlag() {
        let recording = TranscriptDetailViewModel(session: RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            title: "Session",
            capturedAppName: "Zoom",
            status: .done
        ), aiProviderService: makeAIProviderService())
        XCTAssertEqual(recording.applicationName, "Zoom")
        XCTAssertFalse(recording.isReprocessed)

        let imported = TranscriptDetailViewModel(session: ImportedSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 4,
            mixdownURL: "/tmp/mix.m4a",
            title: "Imported",
            originalFileName: "sample.wav",
            originalFormat: "wav",
            status: .done
        ), aiProviderService: makeAIProviderService())
        XCTAssertNil(imported.applicationName)
    }

    @MainActor
    private func makeAIProviderService() -> AIProviderService {
        let defaults = UserDefaults(suiteName: "RecordingStatusTests.\(UUID().uuidString)") ?? .standard
        let keychainStore = MockKeychainStore()
        return AIProviderService(
            keychainStore: keychainStore,
            store: AIProviderStore(defaults: defaults)
        )
    }
}

final class RecordingSessionTests: XCTestCase {
    func testRecordingSessionAITransformationHistoryRoundTrips() {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 42,
            micAudioURL: "/tmp/mic.wav",
            title: "Demo",
            status: .done
        )
        let transformations = [
            AITransformation(
                promptName: "Summary",
                modelID: "gpt-5.2",
                resultText: "Short summary",
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            AITransformation(
                promptName: "Action Items",
                modelID: "gpt-5.2",
                resultText: "1. Follow up",
                createdAt: Date(timeIntervalSince1970: 200)
            )
        ]

        session.aiTransformations = transformations

        XCTAssertEqual(session.aiTransformations, transformations)
        XCTAssertNotNil(session.aiTransformationsData)
    }

    func testImportedSessionAITransformationHistoryRoundTrips() {
        let session = ImportedSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 12,
            mixdownURL: "/tmp/mix.m4a",
            title: "Imported",
            originalFileName: "sample.wav",
            originalFormat: "wav",
            status: .done
        )
        let transformations = [
            AITransformation(
                promptName: "Summary",
                modelID: "gpt-5.2",
                resultText: "Imported summary",
                createdAt: Date(timeIntervalSince1970: 300)
            )
        ]

        session.aiTransformations = transformations

        XCTAssertEqual(session.aiTransformations, transformations)
        XCTAssertNotNil(session.aiTransformationsData)
    }

    func testTranscriptDetailViewIncludesAITransformationUIElements() throws {
        let source = try transcriptDetailSource()

        XCTAssertTrue(source.contains("Text(\"AI Transformations\")"))
        XCTAssertTrue(source.contains("Picker(\"Prompt\""))
        XCTAssertTrue(source.contains("Picker(\"History\""))
        XCTAssertTrue(source.contains("SkeletonView()"))
        XCTAssertTrue(source.contains("Add prompts in Settings to enable transformations."))
        XCTAssertTrue(source.contains("40,000"))
    }

    func testTranscriptDetailViewIncludesPreviewAndStudyNavigation() throws {
        let source = try transcriptDetailSource()

        XCTAssertTrue(source.contains("TranscriptPreviewView("))
        XCTAssertTrue(source.contains("onTap: viewModel.displayedTranscript == nil ? nil : onOpenStudy"))
        XCTAssertFalse(source.contains("Label(\"Study Transcript\", systemImage: \"book.pages\")"))
        XCTAssertFalse(source.contains(".sheet(isPresented: $showingStudyTranscript)"))
    }

    func testTranscriptConversationViewsUseAdaptiveStylesForLightDarkMode() throws {
        let blockSource = try sourceForFile(named: "TranscriptBlockView.swift")
        let previewSource = try sourceForFile(named: "TranscriptPreviewView.swift")
        let studySource = try sourceForFile(named: "TranscriptStudyView.swift")

        XCTAssertTrue(blockSource.contains(".background(.thinMaterial"))
        XCTAssertTrue(blockSource.contains(".foregroundStyle(.primary)"))
        XCTAssertFalse(blockSource.contains("Color.white"))
        XCTAssertFalse(blockSource.contains("Color.black"))

        XCTAssertTrue(previewSource.contains(".background(.thinMaterial"))
        XCTAssertTrue(studySource.contains(".background(.bar)"))
    }

    private func transcriptDetailSource() throws -> String {
        try sourceForFile(named: "TranscriptDetailView.swift")
    }

    private func sourceForFile(named fileName: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent("../UI/\(fileName)")
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
