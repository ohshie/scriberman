import AVFoundation
import Combine
import CoreAudio
import Foundation

private let audioObjectSystemObjectID = AudioObjectID(kAudioObjectSystemObject)
private let audioStreamDirectionInput: UInt32 = 1

protocol AudioDeviceHardwareProviding {
    func allDeviceIDs() throws -> [AudioDeviceID]
    func hasInputStream(deviceID: AudioDeviceID) -> Bool
    func deviceUID(deviceID: AudioDeviceID) -> String?
    func deviceName(deviceID: AudioDeviceID) -> String?
    func defaultInputDeviceID() -> AudioDeviceID?
}

struct CoreAudioDeviceHardware: AudioDeviceHardwareProviding {
    func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            audioObjectSystemObjectID,
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else {
            return []
        }
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        status = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                audioObjectSystemObjectID,
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }

        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        return deviceIDs
    }

    func hasInputStream(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var direction = audioStreamDirectionInput
        var dataSize: UInt32 = 0

        let status = withUnsafePointer(to: &direction) { directionPointer in
            AudioObjectGetPropertyDataSize(
                deviceID,
                &address,
                UInt32(MemoryLayout<UInt32>.size),
                directionPointer,
                &dataSize
            )
        }

        return status == noErr && dataSize >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    func deviceUID(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                uidPointer
            )
        }

        guard status == noErr, let uid else {
            return nil
        }

        return uid as String
    }

    func deviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { namePointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                namePointer
            )
        }

        guard status == noErr, let name else {
            return nil
        }

        return name as String
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &deviceID) { deviceIDPointer in
            AudioObjectGetPropertyData(
                audioObjectSystemObjectID,
                &address,
                0,
                nil,
                &dataSize,
                deviceIDPointer
            )
        }

        guard status == noErr else {
            return nil
        }

        return deviceID
    }
}

@MainActor
final class AudioDeviceService: ObservableObject, AudioDeviceServiceProtocol {
    @Published var availableDevices: [AudioInputDevice] = []
    @Published var selectedDevice: AudioInputDevice? {
        didSet {
            guard !isApplyingSelection else {
                return
            }
            lastDisconnectedSelectedUID = nil
            persistSelectedUID()
        }
    }

    var availableDevicesPublisher: AnyPublisher<[AudioInputDevice], Never> {
        $availableDevices.eraseToAnyPublisher()
    }

    var selectedDevicePublisher: AnyPublisher<AudioInputDevice?, Never> {
        $selectedDevice.eraseToAnyPublisher()
    }

    private let hardware: AudioDeviceHardwareProviding
    private let userDefaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let hardwareListenerQueue: DispatchQueue
    private lazy var hardwarePropertyListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
            self?.refreshDevices()
        }
    }
    private let selectedMicUIDKey = "selectedMicUID"
    private let deviceUsageScoresKey = "deviceUsageScores"
    private var configurationObserver: NSObjectProtocol?
    private var isApplyingSelection = false
    private var deviceUsageScores: [String: Int]
    private var lastDisconnectedSelectedUID: String?

    init(
        hardware: AudioDeviceHardwareProviding = CoreAudioDeviceHardware(),
        userDefaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        hardwareListenerQueue: DispatchQueue = .main
    ) {
        self.hardware = hardware
        self.userDefaults = userDefaults
        self.notificationCenter = notificationCenter
        self.hardwareListenerQueue = hardwareListenerQueue
        self.deviceUsageScores = Self.loadUsageScores(from: userDefaults, key: "deviceUsageScores")

        availableDevices = enumerateInputDevices()
        revalidateSelectedDevice()
        registerHardwarePropertyListeners()

        configurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
            }
        }
    }

    deinit {
        if let configurationObserver {
            notificationCenter.removeObserver(configurationObserver)
        }
    }

    func enumerateInputDevices() -> [AudioInputDevice] {
        do {
            let devices = try hardware.allDeviceIDs().compactMap { deviceID -> AudioInputDevice? in
                guard hardware.hasInputStream(deviceID: deviceID),
                      let uid = hardware.deviceUID(deviceID: deviceID),
                      let name = hardware.deviceName(deviceID: deviceID)
                else {
                    return nil
                }

                return AudioInputDevice(id: deviceID, uid: uid, name: name)
            }

            return sortedDevices(devices)
        } catch {
            return []
        }
    }

    func refreshDevices() {
        availableDevices = enumerateInputDevices()
        revalidateSelectedDevice()
    }

    func incrementUsage(for uid: String) {
        guard !uid.isEmpty else {
            return
        }
        deviceUsageScores[uid, default: 0] += 1
        persistUsageScores()
        availableDevices = sortedDevices(availableDevices)
    }

    private func persistSelectedUID() {
        if let uid = selectedDevice?.uid {
            userDefaults.set(uid, forKey: selectedMicUIDKey)
        } else {
            userDefaults.removeObject(forKey: selectedMicUIDKey)
        }
    }

    private func revalidateSelectedDevice() {
        let defaultDevice = currentDefaultInputDevice()

        if let currentUID = selectedDevice?.uid,
           let matchingCurrent = device(withUID: currentUID) {
            applySelection(matchingCurrent, persist: false)
            recoverDisconnectedDeviceIfNeeded(defaultDevice: defaultDevice)
            return
        }

        if let currentUID = selectedDevice?.uid {
            lastDisconnectedSelectedUID = currentUID
            applySelection(defaultDevice ?? availableDevices.first, persist: true)
            return
        }

        let savedUID = userDefaults.string(forKey: selectedMicUIDKey)
        if let savedUID,
           let restored = device(withUID: savedUID) {
            applySelection(restored, persist: false)
            return
        }

        if savedUID != nil {
            userDefaults.removeObject(forKey: selectedMicUIDKey)
        }

        if let defaultDevice {
            applySelection(defaultDevice, persist: false)
            return
        }

        applySelection(availableDevices.first, persist: false)
    }

    private func sortedDevices(_ devices: [AudioInputDevice]) -> [AudioInputDevice] {
        devices.sorted { lhs, rhs in
            let lhsUsage = deviceUsageScores[lhs.uid, default: 0]
            let rhsUsage = deviceUsageScores[rhs.uid, default: 0]
            if lhsUsage != rhsUsage {
                return lhsUsage > rhsUsage
            }

            let nameCompare = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameCompare != .orderedSame {
                return nameCompare == .orderedAscending
            }
            return lhs.uid < rhs.uid
        }
    }

    private func persistUsageScores() {
        userDefaults.set(deviceUsageScores, forKey: deviceUsageScoresKey)
    }

    private static func loadUsageScores(from userDefaults: UserDefaults, key: String) -> [String: Int] {
        guard let rawScores = userDefaults.dictionary(forKey: key) else {
            return [:]
        }
        return rawScores.reduce(into: [String: Int]()) { result, entry in
            if let value = entry.value as? Int {
                result[entry.key] = value
                return
            }
            if let value = entry.value as? NSNumber {
                result[entry.key] = value.intValue
            }
        }
    }

    private func registerHardwarePropertyListeners() {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = withUnsafePointer(to: &devicesAddress) { addressPointer in
            AudioObjectAddPropertyListenerBlock(
                audioObjectSystemObjectID,
                addressPointer,
                hardwareListenerQueue,
                hardwarePropertyListener
            )
        }

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = withUnsafePointer(to: &defaultInputAddress) { addressPointer in
            AudioObjectAddPropertyListenerBlock(
                audioObjectSystemObjectID,
                addressPointer,
                hardwareListenerQueue,
                hardwarePropertyListener
            )
        }
    }

    private func currentDefaultInputDevice() -> AudioInputDevice? {
        guard let defaultInputID = hardware.defaultInputDeviceID() else {
            return nil
        }
        return availableDevices.first(where: { $0.id == defaultInputID })
    }

    private func device(withUID uid: String) -> AudioInputDevice? {
        availableDevices.first(where: { $0.uid == uid })
    }

    private func recoverDisconnectedDeviceIfNeeded(defaultDevice: AudioInputDevice?) {
        guard let disconnectedUID = lastDisconnectedSelectedUID,
              let recoveredDevice = device(withUID: disconnectedUID),
              let selectedDevice,
              let defaultDevice,
              selectedDevice.uid == defaultDevice.uid else {
            return
        }
        lastDisconnectedSelectedUID = nil
        applySelection(recoveredDevice, persist: true)
    }

    private func applySelection(_ device: AudioInputDevice?, persist: Bool) {
        isApplyingSelection = true
        selectedDevice = device
        isApplyingSelection = false

        if persist {
            persistSelectedUID()
        }
    }
}
