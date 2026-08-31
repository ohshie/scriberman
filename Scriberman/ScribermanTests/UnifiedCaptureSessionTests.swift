import Foundation
import ScreenCaptureKit
import Testing
@testable import Scriberman

/// Stand-in for `SCStream`, which cannot be constructed in tests: it needs live
/// `SCShareableContent`, a capturable window, and Screen Recording + Microphone TCC grants.
private final class StubCaptureStream: UnifiedCaptureStreaming, @unchecked Sendable {
    var updateError: Error?
    private(set) var updateCallCount = 0
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var addOutputCallCount = 0
    /// Mic device identifiers seen by each `updateConfiguration` call, in order.
    private(set) var appliedMicDeviceUIDs: [String?] = []

    func addStreamOutput(
        _: SCStreamOutput,
        type _: SCStreamOutputType,
        sampleHandlerQueue _: DispatchQueue?
    ) throws {
        addOutputCallCount += 1
    }

    func startCapture() async throws {
        startCallCount += 1
    }

    func stopCapture() async throws {
        stopCallCount += 1
    }

    func updateConfiguration(_ configuration: SCStreamConfiguration) async throws {
        updateCallCount += 1
        appliedMicDeviceUIDs.append(configuration.microphoneCaptureDeviceID)
        if let updateError {
            throw updateError
        }
    }
}

private struct StubUpdateError: Error {}

struct UnifiedCaptureSessionTests {
    private func makeSession(micDeviceUID: String?) -> (UnifiedCaptureSession, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = UnifiedCaptureSession(
            micFileURL: root.appendingPathComponent("mic.wav"),
            appFileURL: root.appendingPathComponent("app.wav"),
            processID: 1234,
            micDeviceUID: micDeviceUID
        )
        return (session, root)
    }

    @Test
    func testInitialMicDeviceUIDReflectsRequestedDevice() {
        let (session, _) = makeSession(micDeviceUID: "BuiltInMicrophoneDevice")
        #expect(session.currentMicDeviceUID == "BuiltInMicrophoneDevice")
    }

    @Test
    func testRetargetAppliesNewDeviceToLiveStreamWithoutRestarting() async {
        let (session, _) = makeSession(micDeviceUID: "device-a")
        let stream = StubCaptureStream()
        session.attachStreamForTesting(stream)

        let didRetarget = await session.retargetMic(deviceUID: "device-b")

        #expect(didRetarget)
        #expect(stream.updateCallCount == 1)
        #expect(stream.appliedMicDeviceUIDs == ["device-b"])
        #expect(session.currentMicDeviceUID == "device-b")
        // The stream must not be torn down or rebuilt to change the microphone.
        #expect(stream.stopCallCount == 0)
        #expect(stream.startCallCount == 0)
        #expect(stream.addOutputCallCount == 0)
    }

    @Test
    func testRetargetToSystemDefaultClearsTheDeviceIdentifier() async {
        let (session, _) = makeSession(micDeviceUID: "device-a")
        let stream = StubCaptureStream()
        session.attachStreamForTesting(stream)

        let didRetarget = await session.retargetMic(deviceUID: nil)

        #expect(didRetarget)
        #expect(stream.appliedMicDeviceUIDs == [nil])
        #expect(session.currentMicDeviceUID == nil)
    }

    @Test
    func testFailedRetargetKeepsPreviousDeviceAndReportsFailure() async {
        let (session, _) = makeSession(micDeviceUID: "device-a")
        let stream = StubCaptureStream()
        stream.updateError = StubUpdateError()
        session.attachStreamForTesting(stream)

        let didRetarget = await session.retargetMic(deviceUID: "device-b")

        #expect(!didRetarget)
        #expect(session.currentMicDeviceUID == "device-a")
        // Capture continues: the stream is neither stopped nor restarted on failure.
        #expect(stream.stopCallCount == 0)
        #expect(stream.startCallCount == 0)
    }

    @Test
    func testFailedRetargetRollsBackRetainedConfiguration() async {
        let (session, _) = makeSession(micDeviceUID: "device-a")
        let stream = StubCaptureStream()
        stream.updateError = StubUpdateError()
        session.attachStreamForTesting(stream)

        _ = await session.retargetMic(deviceUID: "device-b")
        stream.updateError = nil
        // A later successful retarget must not carry over the rejected value; the configuration
        // has to still describe what the stream actually has.
        let didRetarget = await session.retargetMic(deviceUID: "device-c")

        #expect(didRetarget)
        #expect(stream.appliedMicDeviceUIDs == ["device-b", "device-c"])
        #expect(session.currentMicDeviceUID == "device-c")
    }

    @Test
    func testRetargetWithoutRunningStreamFails() async {
        let (session, _) = makeSession(micDeviceUID: "device-a")

        let didRetarget = await session.retargetMic(deviceUID: "device-b")

        #expect(!didRetarget)
        #expect(session.currentMicDeviceUID == "device-a")
    }
}
