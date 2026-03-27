import Combine
import Foundation
@testable import Scriberman

@MainActor
final class MockAudioDeviceService: AudioDeviceServiceProtocol {
    @Published var availableDevices: [AudioInputDevice] = []
    @Published var selectedDevice: AudioInputDevice?

    var availableDevicesPublisher: AnyPublisher<[AudioInputDevice], Never> {
        $availableDevices.eraseToAnyPublisher()
    }

    var selectedDevicePublisher: AnyPublisher<AudioInputDevice?, Never> {
        $selectedDevice.eraseToAnyPublisher()
    }
}
