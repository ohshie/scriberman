import XCTest
@testable import Scriberman

final class RecordingStatusTests: XCTestCase {
    func testNonErrorStatusesRoundTripPersistence() {
        let statuses: [RecordingStatus] = [.recorded, .transcribing, .done]

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
            audioURL: "/tmp/audio.wav",
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
            audioURL: "/tmp/audio.wav",
            title: "Session",
            status: .recorded
        )

        XCTAssertNil(session.capturedAppName)
    }
}
