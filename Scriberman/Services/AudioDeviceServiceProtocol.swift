import Combine
import Foundation

@MainActor
protocol AudioDeviceServiceProtocol: AnyObject {
    var availableDevices: [AudioInputDevice] { get }
    var selectedDevice: AudioInputDevice? { get set }
    var availableDevicesPublisher: AnyPublisher<[AudioInputDevice], Never> { get }
    var selectedDevicePublisher: AnyPublisher<AudioInputDevice?, Never> { get }
}
