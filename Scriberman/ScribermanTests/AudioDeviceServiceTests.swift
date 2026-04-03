import AVFoundation
import CoreAudio
import Testing
@testable import Scriberman

@MainActor
final class AudioDeviceServiceTests {
    nonisolated(unsafe) private var hardware: MockAudioDeviceHardware!
    nonisolated(unsafe) private var userDefaults: UserDefaults!
    nonisolated(unsafe) private var notificationCenter: NotificationCenter!
    nonisolated(unsafe) private var service: AudioDeviceService!
    nonisolated(unsafe) private var userDefaultsSuiteName: String!

    init() {
        hardware = MockAudioDeviceHardware()
        notificationCenter = NotificationCenter()
        userDefaultsSuiteName = "AudioDeviceServiceTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }

    deinit {
        service = nil
        if let userDefaultsSuiteName {
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        userDefaults = nil
        userDefaultsSuiteName = nil
        notificationCenter = nil
        hardware = nil
    }

    @Test

    func testEnumerateInputDevicesFiltersOutputOnlyAndSortsByUsageThenName() {
        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Zulu Mic", hasInput: true),
            MockAudioDevice(id: 2, uid: "uid-2", name: "Output Device", hasInput: false),
            MockAudioDevice(id: 3, uid: "uid-3", name: "Alpha Mic", hasInput: true),
            MockAudioDevice(id: 4, uid: "uid-4", name: "Bravo Mic", hasInput: true)
        ]
        hardware.defaultInputID = 1
        userDefaults.set(["uid-1": 5, "uid-3": 2], forKey: "deviceUsageScores")

        service = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        #expect(service.availableDevices.map(\.uid) == ["uid-1", "uid-3", "uid-4"])
    }

    @Test

    func testIncrementUsagePersistsUsageScoresAndResortsDevices() {
        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Zulu Mic", hasInput: true),
            MockAudioDevice(id: 2, uid: "uid-2", name: "Alpha Mic", hasInput: true)
        ]
        hardware.defaultInputID = 1

        service = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        #expect(service.availableDevices.map(\.uid) == ["uid-2", "uid-1"])

        service.incrementUsage(for: "uid-1")

        let persistedScores = userDefaults.dictionary(forKey: "deviceUsageScores") as? [String: Int]
        #expect(persistedScores?["uid-1"] == 1)
        #expect(service.availableDevices.map(\.uid) == ["uid-1", "uid-2"])
    }

    @Test

    func testUsageScoresPersistAcrossServiceRecreation() {
        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Mic One", hasInput: true),
            MockAudioDevice(id: 2, uid: "uid-2", name: "Mic Two", hasInput: true)
        ]
        hardware.defaultInputID = 1

        service = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )
        service.incrementUsage(for: "uid-2")
        service.incrementUsage(for: "uid-2")
        service = nil

        let recreated = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        #expect(recreated.availableDevices.map(\.uid) == ["uid-2", "uid-1"])
    }

    @Test

    func testSelectedDevicePersistsUID() {
        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Mic One", hasInput: true),
            MockAudioDevice(id: 2, uid: "uid-2", name: "Mic Two", hasInput: true)
        ]
        hardware.defaultInputID = 1

        service = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        service.selectedDevice = service.availableDevices.first(where: { $0.uid == "uid-2" })

        #expect(userDefaults.string(forKey: "selectedMicUID") == "uid-2")
    }

    @Test

    func testRestoreSelectionBySavedUIDOnLaunch() {
        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Mic One", hasInput: true),
            MockAudioDevice(id: 2, uid: "uid-2", name: "Mic Two", hasInput: true)
        ]
        hardware.defaultInputID = 1
        userDefaults.set("uid-2", forKey: "selectedMicUID")

        service = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        #expect(service.selectedDevice?.uid == "uid-2")
    }

    @Test

    func testMissingSavedUIDClearsPersistenceAndFallsBackToDefaultInput() {
        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Default Mic", hasInput: true),
            MockAudioDevice(id: 2, uid: "uid-2", name: "Second Mic", hasInput: true)
        ]
        hardware.defaultInputID = 1
        userDefaults.set("missing-uid", forKey: "selectedMicUID")

        service = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        #expect(service.selectedDevice?.uid == "uid-1")
        #expect(userDefaults.string(forKey: "selectedMicUID") == nil)
    }

    @Test

    func testConfigurationChangeRefreshesDevicesAndRevalidatesSelection() async throws {
        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "First Mic", hasInput: true)
        ]
        hardware.defaultInputID = 1

        service = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        #expect(service.selectedDevice?.uid == "uid-1")

        hardware.devices = [
            MockAudioDevice(id: 2, uid: "uid-2", name: "Second Mic", hasInput: true)
        ]
        hardware.defaultInputID = 2

        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.availableDevices.map(\.uid) == ["uid-2"])
        #expect(service.selectedDevice?.uid == "uid-2")
    }

    @Test

    func testRefreshDevicesFallsBackToSystemDefaultWhenSelectedDeviceIsRemoved() {
        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Built-in Mic", hasInput: true),
            MockAudioDevice(id: 2, uid: "uid-2", name: "AirPods Mic", hasInput: true)
        ]
        hardware.defaultInputID = 1

        service = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )
        service.selectedDevice = service.availableDevices.first(where: { $0.uid == "uid-2" })

        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Built-in Mic", hasInput: true)
        ]
        hardware.defaultInputID = 1

        service.refreshDevices()

        #expect(service.selectedDevice?.uid == "uid-1")
    }

    @Test

    func testRefreshDevicesRecoversDisconnectedDeviceWhenCurrentSelectionIsDefault() {
        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Built-in Mic", hasInput: true),
            MockAudioDevice(id: 2, uid: "uid-2", name: "AirPods Mic", hasInput: true)
        ]
        hardware.defaultInputID = 1

        service = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )
        service.selectedDevice = service.availableDevices.first(where: { $0.uid == "uid-2" })

        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Built-in Mic", hasInput: true)
        ]
        service.refreshDevices()
        #expect(service.selectedDevice?.uid == "uid-1")

        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Built-in Mic", hasInput: true),
            MockAudioDevice(id: 2, uid: "uid-2", name: "AirPods Mic", hasInput: true)
        ]
        hardware.defaultInputID = 1

        service.refreshDevices()

        #expect(service.selectedDevice?.uid == "uid-2")
    }

    @Test

    func testRefreshDevicesDoesNotRecoverDisconnectedDeviceAfterManualOverride() {
        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Built-in Mic", hasInput: true),
            MockAudioDevice(id: 2, uid: "uid-2", name: "AirPods Mic", hasInput: true),
            MockAudioDevice(id: 3, uid: "uid-3", name: "USB Mic", hasInput: true)
        ]
        hardware.defaultInputID = 1

        service = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )
        service.selectedDevice = service.availableDevices.first(where: { $0.uid == "uid-2" })

        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Built-in Mic", hasInput: true),
            MockAudioDevice(id: 3, uid: "uid-3", name: "USB Mic", hasInput: true)
        ]
        service.refreshDevices()
        #expect(service.selectedDevice?.uid == "uid-1")

        service.selectedDevice = service.availableDevices.first(where: { $0.uid == "uid-3" })
        #expect(service.selectedDevice?.uid == "uid-3")

        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Built-in Mic", hasInput: true),
            MockAudioDevice(id: 2, uid: "uid-2", name: "AirPods Mic", hasInput: true),
            MockAudioDevice(id: 3, uid: "uid-3", name: "USB Mic", hasInput: true)
        ]
        service.refreshDevices()

        #expect(service.selectedDevice?.uid == "uid-3")
    }
}

private struct MockAudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let hasInput: Bool
}

private final class MockAudioDeviceHardware: AudioDeviceHardwareProviding {
    var devices: [MockAudioDevice] = []
    var defaultInputID: AudioDeviceID?

    func allDeviceIDs() throws -> [AudioDeviceID] {
        devices.map(\.id)
    }

    func hasInputStream(deviceID: AudioDeviceID) -> Bool {
        devices.first(where: { $0.id == deviceID })?.hasInput ?? false
    }

    func deviceUID(deviceID: AudioDeviceID) -> String? {
        devices.first(where: { $0.id == deviceID })?.uid
    }

    func deviceName(deviceID: AudioDeviceID) -> String? {
        devices.first(where: { $0.id == deviceID })?.name
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        defaultInputID
    }
}
