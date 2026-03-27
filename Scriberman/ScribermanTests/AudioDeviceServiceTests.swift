import AVFoundation
import CoreAudio
import XCTest
@testable import Scriberman

@MainActor
final class AudioDeviceServiceTests: XCTestCase {
    private var hardware: MockAudioDeviceHardware!
    private var userDefaults: UserDefaults!
    private var notificationCenter: NotificationCenter!
    private var service: AudioDeviceService!
    private var userDefaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        hardware = MockAudioDeviceHardware()
        notificationCenter = NotificationCenter()
        userDefaultsSuiteName = "AudioDeviceServiceTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }

    override func tearDown() {
        service = nil
        if let userDefaultsSuiteName {
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        userDefaults = nil
        userDefaultsSuiteName = nil
        notificationCenter = nil
        hardware = nil
        super.tearDown()
    }

    func testEnumerateInputDevicesFiltersOutputOnlyAndSortsByName() {
        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "Zulu Mic", hasInput: true),
            MockAudioDevice(id: 2, uid: "uid-2", name: "Output Device", hasInput: false),
            MockAudioDevice(id: 3, uid: "uid-3", name: "Alpha Mic", hasInput: true)
        ]
        hardware.defaultInputID = 1

        service = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        XCTAssertEqual(service.availableDevices.map(\.uid), ["uid-3", "uid-1"])
    }

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

        XCTAssertEqual(userDefaults.string(forKey: "selectedMicUID"), "uid-2")
    }

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

        XCTAssertEqual(service.selectedDevice?.uid, "uid-2")
    }

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

        XCTAssertEqual(service.selectedDevice?.uid, "uid-1")
        XCTAssertNil(userDefaults.string(forKey: "selectedMicUID"))
    }

    func testConfigurationChangeRefreshesDevicesAndRevalidatesSelection() {
        hardware.devices = [
            MockAudioDevice(id: 1, uid: "uid-1", name: "First Mic", hasInput: true)
        ]
        hardware.defaultInputID = 1

        service = AudioDeviceService(
            hardware: hardware,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        XCTAssertEqual(service.selectedDevice?.uid, "uid-1")

        hardware.devices = [
            MockAudioDevice(id: 2, uid: "uid-2", name: "Second Mic", hasInput: true)
        ]
        hardware.defaultInputID = 2

        notificationCenter.post(name: .AVAudioEngineConfigurationChange, object: nil)

        XCTAssertEqual(service.availableDevices.map(\.uid), ["uid-2"])
        XCTAssertEqual(service.selectedDevice?.uid, "uid-2")
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
