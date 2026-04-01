import Foundation

@MainActor
protocol AudioDeviceServiceProtocol: AnyObject {
    var availableDevices: [AudioInputDevice] { get }
    var selectedDevice: AudioInputDevice? { get set }
    func refreshDevices()
    func incrementUsage(for uid: String)
}
