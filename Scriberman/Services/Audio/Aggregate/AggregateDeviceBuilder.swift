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
