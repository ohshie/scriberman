import CoreAudio
import Foundation

enum AggregateDeviceBuilderError: LocalizedError {
    case failedToResolveProcessObject(OSStatus)
    case failedToCreateTap(OSStatus)
    case failedToCreateAggregateDevice(OSStatus)
    case failedToUpdateTapList(OSStatus)

    var errorDescription: String? {
        switch self {
        case .failedToResolveProcessObject(let status):
            return "Failed to resolve process object for tap creation (OSStatus \(status))."
        case .failedToCreateTap(let status):
            return "Failed to create process tap (OSStatus \(status))."
        case .failedToCreateAggregateDevice(let status):
            return "Failed to create aggregate device (OSStatus \(status))."
        case .failedToUpdateTapList(let status):
            return "Failed to update aggregate tap list (OSStatus \(status))."
        }
    }
}

protocol AggregateDeviceHardwareProviding {
    func processObjectID(for pid: pid_t) throws -> AudioObjectID
    func createProcessTap(description: CATapDescription) throws -> AudioObjectID
    func createAggregateDevice(description: CFDictionary) throws -> AudioDeviceID
    func updateAggregateTapList(aggregateDeviceID: AudioDeviceID, tapUID: String) throws
    func destroyProcessTap(_ tapID: AudioObjectID)
    func destroyAggregateDevice(_ aggregateDeviceID: AudioDeviceID)
}

struct AggregateDeviceHardware: AggregateDeviceHardwareProviding {
    func processObjectID(for pid: pid_t) throws -> AudioObjectID {
        var pidValue = pid
        var processObjectID: AudioObjectID = 0
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = withUnsafePointer(to: &pidValue) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifier,
                &dataSize,
                &processObjectID
            )
        }

        guard status == noErr else {
            throw AggregateDeviceBuilderError.failedToResolveProcessObject(status)
        }

        return processObjectID
    }

    func createProcessTap(description: CATapDescription) throws -> AudioObjectID {
        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw AggregateDeviceBuilderError.failedToCreateTap(status)
        }
        return tapID
    }

    func createAggregateDevice(description: CFDictionary) throws -> AudioDeviceID {
        var deviceID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description, &deviceID)
        guard status == noErr else {
            throw AggregateDeviceBuilderError.failedToCreateAggregateDevice(status)
        }
        return deviceID
    }

    func updateAggregateTapList(aggregateDeviceID: AudioDeviceID, tapUID: String) throws {
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID
        ]
        var tapList: CFArray = [tapEntry] as CFArray

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = withUnsafeMutablePointer(to: &tapList) { tapListPointer in
            AudioObjectSetPropertyData(
                aggregateDeviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CFArray>.size),
                tapListPointer
            )
        }

        guard status == noErr else {
            throw AggregateDeviceBuilderError.failedToUpdateTapList(status)
        }
    }

    func destroyProcessTap(_ tapID: AudioObjectID) {
        AudioHardwareDestroyProcessTap(tapID)
    }

    func destroyAggregateDevice(_ aggregateDeviceID: AudioDeviceID) {
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    }
}

protocol AggregateDeviceBuilding {
    func createTap(for pid: pid_t) throws -> AudioObjectID
    func createAggregateDevice(micUID: String, tapID: AudioObjectID) throws -> AudioDeviceID
    func teardown(tapID: AudioObjectID, aggregateDeviceID: AudioDeviceID)
    func destroyTap(_ tapID: AudioObjectID)
}

struct AggregateDeviceBuilder: AggregateDeviceBuilding {
    private let hardware: AggregateDeviceHardwareProviding

    init(hardware: AggregateDeviceHardwareProviding = AggregateDeviceHardware()) {
        self.hardware = hardware
    }

    func createTap(for pid: pid_t) throws -> AudioObjectID {
        let processObjectID = try hardware.processObjectID(for: pid)
        let tapDescription = CATapDescription(
            stereoMixdownOfProcesses: [processObjectID]
        )
        return try hardware.createProcessTap(description: tapDescription)
    }

    func createAggregateDevice(micUID: String, tapID: AudioObjectID) throws -> AudioDeviceID {
        let aggregateName = "Scriberman Aggregate \(UUID().uuidString.prefix(8))"
        let aggregateUID = "com.scriberman.aggregate.\(UUID().uuidString)"
        let tapUID = "com.scriberman.tap.\(tapID)"

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ]
        ]

        let aggregateDeviceID = try hardware.createAggregateDevice(description: description as CFDictionary)
        do {
            try hardware.updateAggregateTapList(aggregateDeviceID: aggregateDeviceID, tapUID: tapUID)
            return aggregateDeviceID
        } catch {
            hardware.destroyAggregateDevice(aggregateDeviceID)
            throw error
        }
    }

    func teardown(tapID: AudioObjectID, aggregateDeviceID: AudioDeviceID) {
        hardware.destroyProcessTap(tapID)
        hardware.destroyAggregateDevice(aggregateDeviceID)
    }

    func destroyTap(_ tapID: AudioObjectID) {
        hardware.destroyProcessTap(tapID)
    }
}
