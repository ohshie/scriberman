import Foundation

@MainActor
protocol AudioDeviceServiceProtocol: AnyObject {
    var availableDevices: [AudioInputDevice] { get }
    /// The device in use now. Setting it is an explicit pick: it also becomes `preferredDeviceUID`.
    var selectedDevice: AudioInputDevice? { get set }
    /// The microphone the user chose, saved across launches. It differs from `selectedDevice` while
    /// that device is absent and the selection is a fallback. `nil` follows the system default.
    var preferredDeviceUID: String? { get }
    func refreshDevices()
    func incrementUsage(for uid: String)
}
