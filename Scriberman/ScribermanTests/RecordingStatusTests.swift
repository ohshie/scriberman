import XCTest
@testable import Scriberman

final class RecordingStatusTests: XCTestCase {
    func testNonErrorStatusesRoundTripPersistence() {
        let statuses: [RecordingStatus] = [.recorded, .transcribing, .retranscribing, .done]

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
}
