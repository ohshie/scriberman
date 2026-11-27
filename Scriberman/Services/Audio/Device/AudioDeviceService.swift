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
            persistSelectedUID()
        }
    }

    /// Saved in `selectedMicUID`. Written only by an explicit pick, so a fallback leaves it, and
    /// read at every revalidation, so the saved device is selected again when it appears, also
    /// after a relaunch during its absence.
    var preferredDeviceUID: String? {
        userDefaults.string(forKey: selectedMicUIDKey)
    }

    @ObservationIgnored private let hardware: AudioDeviceHardwareProviding
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let hardwareListenerQueue: DispatchQueue
    @ObservationIgnored private lazy var hardwarePropertyListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
            self?.refreshDevices()
        }
    }
    @ObservationIgnored private let selectedMicUIDKey = "selectedMicUID"
    // nonisolated(unsafe): written once in init, removed in deinit; never mutated concurrently
    @ObservationIgnored nonisolated(unsafe) private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private var isApplyingSelection = false
    @ObservationIgnored private let usageStore: AudioDeviceUsageStore

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
        usageStore = AudioDeviceUsageStore(userDefaults: userDefaults)

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
                // Offered only if it can capture now. An unusable device is absent from the list
                // rather than present and unavailable.
                guard hardware.isUsableMicrophone(deviceID: deviceID),
                      let uid = hardware.deviceUID(deviceID: deviceID),
                      let name = hardware.deviceName(deviceID: deviceID)
                else {
                    return nil
                }

                return AudioInputDevice(id: deviceID, uid: uid, name: name)
            }

            return usageStore.sort(devices)
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
        usageStore.increment(uid: uid)
        availableDevices = usageStore.sort(availableDevices)
    }

    private func persistSelectedUID() {
        if let uid = selectedDevice?.uid {
            userDefaults.set(uid, forKey: selectedMicUIDKey)
        } else {
            userDefaults.removeObject(forKey: selectedMicUIDKey)
        }
    }

    /// Selects the preferred device when it is offered, otherwise keeps a current selection that is
    /// still offered, otherwise falls back to the system default. A fallback never writes the
    /// preference. A preference that names a device present and alive but unusable as a microphone
    /// (no input channels, a private aggregate) is cleared; one that is absent or dying is kept.
    private func revalidateSelectedDevice() {
        if let preferredUID = preferredDeviceUID {
            if let preferred = device(withUID: preferredUID) {
                applySelection(preferred)
                return
            }
            if isPresentButUnusable(uid: preferredUID) {
                userDefaults.removeObject(forKey: selectedMicUIDKey)
            }
        }

        if let currentUID = selectedDevice?.uid,
           let matchingCurrent = device(withUID: currentUID) {
            applySelection(matchingCurrent)
            return
        }

        applySelection(currentDefaultInputDevice() ?? availableDevices.first)
    }

    private func isPresentButUnusable(uid: String) -> Bool {
        guard let deviceIDs = try? hardware.allDeviceIDs() else {
            return false
        }
        return deviceIDs.contains { deviceID in
            hardware.deviceUID(deviceID: deviceID) == uid
                && hardware.isAlive(deviceID: deviceID)
                && !hardware.isUsableMicrophone(deviceID: deviceID)
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

    /// Changes the current selection without touching the saved preference.
    private func applySelection(_ device: AudioInputDevice?) {
        isApplyingSelection = true
        selectedDevice = device
        isApplyingSelection = false
    }
}
