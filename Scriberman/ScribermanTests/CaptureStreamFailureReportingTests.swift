import Foundation
import ScreenCaptureKit
import SwiftData
import Testing
@testable import Scriberman

/// Covers the path a stopped capture stream takes to reach the recording.
///
/// Before this existed, `stream(_:didStopWithError:)` logged the error and returned unless it was a
/// TCC denial, so a stream that died mid-recording left `isRecordingValue == true` and the app went
/// on reporting a healthy recording. Two such deaths were observed in one session:
/// "Failed to find any displays or windows to capture" and "Failed during stream due to application
/// connection being interrupted".
struct CaptureStreamFailureReportingTests {
    /// Mirrors an `SCStreamErrorDomain` TCC denial without needing a real `SCStream`.
    private static func tccDeniedError() -> NSError {
        NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "TCC access denied"]
        )
    }

    /// `SCStreamErrorNoCaptureSource`. Observed in the wild as the filter's window disappearing.
    /// Deliberately not `-3801`, which is `userDeclined` — a fabricated code that collides with it
    /// would make this look like a permission failure.
    private static func windowLostError() -> NSError {
        NSError(
            domain: SCStreamErrorDomain,
            code: -3815,
            userInfo: [NSLocalizedDescriptionKey: "Failed to find any displays or windows to capture"]
        )
    }

    /// `SCStreamErrorFailedApplicationConnectionInterrupted`.
    private static func connectionInterruptedError() -> NSError {
        NSError(
            domain: SCStreamErrorDomain,
            code: -3805,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Failed during stream due to application connection being interrupted"
            ]
        )
    }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _errors: [String] = []
        func record(_ error: any Error) {
            lock.lock()
            _errors.append(error.localizedDescription)
            lock.unlock()
        }
        var errors: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _errors
        }
    }

    private final class StubCaptureStream: UnifiedCaptureStreaming, @unchecked Sendable {
        private(set) var stopCallCount = 0
        func addStreamOutput(
            _: SCStreamOutput,
            type _: SCStreamOutputType,
            sampleHandlerQueue _: DispatchQueue?
        ) throws {}
        func startCapture() async throws {}
        func stopCapture() async throws { stopCallCount += 1 }
        func updateConfiguration(_: SCStreamConfiguration) async throws {}
    }

    private func makeUnifiedSession(
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> UnifiedCaptureSession {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return UnifiedCaptureSession(
            micFileURL: root.appendingPathComponent("mic.wav"),
            appFileURL: root.appendingPathComponent("app.wav"),
            processID: 1234,
            micDeviceUID: "device-a",
            notificationCenter: notificationCenter
        )
    }

    // MARK: - UnifiedCaptureSession

    @Test
    func testNonTCCStreamErrorIsReportedToTheOwner() {
        let session = makeUnifiedSession()
        let box = ErrorBox()
        session.onStreamStopped = { [box] error in box.record(error) }

        session.handleStreamStoppedForTesting(Self.windowLostError())

        #expect(box.errors == ["Failed to find any displays or windows to capture"])
    }

    @Test
    func testConnectionInterruptedErrorIsReportedToTheOwner() {
        let session = makeUnifiedSession()
        let box = ErrorBox()
        session.onStreamStopped = { [box] error in box.record(error) }

        session.handleStreamStoppedForTesting(Self.connectionInterruptedError())

        #expect(box.errors == ["Failed during stream due to application connection being interrupted"])
    }

    @Test
    func testTCCErrorBothPostsTheNotificationAndReportsToTheOwner() async {
        let center = NotificationCenter()
        let session = makeUnifiedSession(notificationCenter: center)
        let box = ErrorBox()
        session.onStreamStopped = { [box] error in box.record(error) }

        let posted = ErrorBox()
        let token = center.addObserver(
            forName: .appAudioCaptureAccessDenied,
            object: nil,
            queue: nil
        ) { [posted] notification in
            let description = notification.userInfo?["errorDescription"] as? String ?? ""
            posted.record(NSError(
                domain: "test",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: description]
            ))
        }
        defer { center.removeObserver(token) }

        session.handleStreamStoppedForTesting(Self.tccDeniedError())

        // The existing permission notification must keep working, and the owner must hear about it
        // too — a TCC denial ends the recording's audio exactly like any other stream death.
        #expect(posted.errors == ["TCC access denied"])
        #expect(box.errors == ["TCC access denied"])
    }

    @Test
    func testNonTCCErrorDoesNotPostThePermissionNotification() {
        let center = NotificationCenter()
        let session = makeUnifiedSession(notificationCenter: center)

        let posted = ErrorBox()
        let token = center.addObserver(
            forName: .appAudioCaptureAccessDenied,
            object: nil,
            queue: nil
        ) { [posted] _ in
            posted.record(NSError(domain: "test", code: 0))
        }
        defer { center.removeObserver(token) }

        session.handleStreamStoppedForTesting(Self.windowLostError())

        #expect(posted.errors.isEmpty)
    }

    @Test
    func testStoppedStreamIsReleasedSoItIsNoLongerTreatedAsActive() async {
        let session = makeUnifiedSession()
        session.attachStreamForTesting(StubCaptureStream())

        session.handleStreamStoppedForTesting(Self.windowLostError())

        // `retargetMic` returns false only when no stream is retained, which is how we observe
        // that the dead stream was let go rather than kept as an active capture.
        let didRetarget = await session.retargetMic(deviceUID: "device-b")
        #expect(!didRetarget)
    }

    @Test
    func testStopDoesNotStopAnAlreadyReleasedStreamASecondTime() async {
        let session = makeUnifiedSession()
        let stream = StubCaptureStream()
        session.attachStreamForTesting(stream)

        session.handleStreamStoppedForTesting(Self.windowLostError())
        await session.stop()

        #expect(stream.stopCallCount == 0)
    }

    // MARK: - AppAudioCaptureSession

    @Test
    func testLegacyAppSessionReportsNonTCCStreamError() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = AppAudioCaptureSession(
            fileURL: root.appendingPathComponent("app.wav"),
            processID: 1234,
            notificationCenter: NotificationCenter()
        )
        let box = ErrorBox()
        session.onStreamStopped = { [box] error in box.record(error) }

        session.handleStreamStoppedForTesting(Self.connectionInterruptedError())

        #expect(box.errors == ["Failed during stream due to application connection being interrupted"])
    }

    // MARK: - RecordingService.pendingError

    @MainActor
    private func makeService() throws -> RecordingService {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: AppAudioSettings()
        )
    }

    @Test @MainActor
    func testReportedFailureSetsPendingErrorWhileRecording() async throws {
        let service = try makeService()
        await service.setRecordingStateForTesting(isRecording: true)

        await service.reportCaptureStreamFailure(Self.connectionInterruptedError())

        let pending = await service.consumePendingError()
        #expect(pending != nil)
        #expect(
            pending?.diagnosticDetail
                == "Failed during stream due to application connection being interrupted"
        )
    }

    @Test @MainActor
    func testPendingErrorIsDeliveredOnceAndCleared() async throws {
        let service = try makeService()
        await service.setRecordingStateForTesting(isRecording: true)
        await service.reportCaptureStreamFailure(Self.windowLostError())

        _ = await service.consumePendingError()
        let second = await service.consumePendingError()

        #expect(second == nil)
    }

    @Test @MainActor
    func testUserFacingWordingIsNotTheRawStreamError() async throws {
        let service = try makeService()
        await service.setRecordingStateForTesting(isRecording: true)
        await service.reportCaptureStreamFailure(Self.windowLostError())

        let pending = await service.consumePendingError()

        // The raw ScreenCaptureKit string is diagnostic only; what the user would see stays the
        // wording already defined on `RecordingError`.
        #expect(pending?.localizedDescription == "Recording stopped because audio capture was interrupted.")
        #expect(pending?.diagnosticDetail == "Failed to find any displays or windows to capture")
    }

    @Test @MainActor
    func testFailureIsIgnoredWhenNotRecording() async throws {
        let service = try makeService()
        await service.setRecordingStateForTesting(isRecording: false)

        await service.reportCaptureStreamFailure(Self.windowLostError())

        // A stream stopping as part of a normal teardown must not leave an error behind for the
        // next recording to pick up.
        let pending = await service.consumePendingError()
        #expect(pending == nil)
    }
}
