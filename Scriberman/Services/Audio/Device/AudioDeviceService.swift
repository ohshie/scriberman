import AVFoundation
import CoreAudio
import Foundation
import Observation

private let audioObjectSystemObjectID = AudioObjectID(kAudioObjectSystemObject)

@MainActor
@Observable
final class AudioDeviceService: AudioDeviceServiceProtocol {
    var availableDevices: [AudioInputDevice] = []
    var selectedDevice: AudioInputDevice? {
        didSet {
            guard !isApplyingSelection else {
                return
            }
            lastDisconnectedSelectedUID = nil
            persistSelectedUID()
        }
    }

    @ObservationIgnored private let hardware: AudioDeviceHardwareProviding
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored nonisolated(unsafe) private let notificationCenter: NotificationCenter
    @ObservationIgnored private let hardwareListenerQueue: DispatchQueue
    @ObservationIgnored private lazy var hardwarePropertyListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
            self?.refreshDevices()
        }
    }
    @ObservationIgnored private let selectedMicUIDKey = "selectedMicUID"
    @ObservationIgnored private let deviceUsageScoresKey = "deviceUsageScores"
    @ObservationIgnored nonisolated(unsafe) private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private var isApplyingSelection = false
    @ObservationIgnored private var deviceUsageScores: [String: Int]
    @ObservationIgnored private var lastDisconnectedSelectedUID: String?

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
