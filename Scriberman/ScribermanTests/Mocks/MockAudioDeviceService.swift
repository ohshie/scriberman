import Combine
import Foundation
@testable import Scriberman

@MainActor
final class MockAudioDeviceService: AudioDeviceServiceProtocol {
    @Published var availableDevices: [AudioInputDevice] = []
    @Published var selectedDevice: AudioInputDevice?
    private(set) var incrementUsageCalls: [String] = []

    var availableDevicesPublisher: AnyPublisher<[AudioInputDevice], Never> {
        $availableDevices.eraseToAnyPublisher()
    }

    var selectedDevicePublisher: AnyPublisher<AudioInputDevice?, Never> {
        $selectedDevice.eraseToAnyPublisher()
    }

    func incrementUsage(for uid: String) {
        incrementUsageCalls.append(uid)
    }
}
