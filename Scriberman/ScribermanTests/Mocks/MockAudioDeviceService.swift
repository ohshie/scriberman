import Foundation
@testable import Scriberman

@MainActor
final class MockAudioDeviceService: AudioDeviceServiceProtocol {
    var availableDevices: [AudioInputDevice] = []
    var selectedDevice: AudioInputDevice?
    private(set) var incrementUsageCalls: [String] = []
    private(set) var refreshDevicesCalls = 0

    func refreshDevices() {
        refreshDevicesCalls += 1
    }

    func incrementUsage(for uid: String) {
        incrementUsageCalls.append(uid)
    }
}
