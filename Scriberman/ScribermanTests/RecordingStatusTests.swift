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

    func testTranscriptDetailStatePrefersRetranscript() {
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

        let state = TranscriptDetailViewState(session: session)
        XCTAssertEqual(state.displayedTranscript?.fullText, "retry")
        XCTAssertEqual(state.finalTranscriptText, "retry")
        XCTAssertEqual(state.originalTranscriptText, "original")
        XCTAssertTrue(state.isReprocessed)
    }

    func testTranscriptDetailStateApplicationNameAndReprocessedFlag() {
        let recording = TranscriptDetailViewState(session: RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            title: "Session",
            capturedAppName: "Zoom",
            status: .done
        ))
        XCTAssertEqual(recording.applicationName, "Zoom")
        XCTAssertFalse(recording.isReprocessed)

        let imported = TranscriptDetailViewState(session: ImportedSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 4,
            mixdownURL: "/tmp/mix.m4a",
            title: "Imported",
            originalFileName: "sample.wav",
            originalFormat: "wav",
            status: .done
        ))
        XCTAssertNil(imported.applicationName)
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

    private func transcriptDetailSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent("../UI/TranscriptDetailView.swift")
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
