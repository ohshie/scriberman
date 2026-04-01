import CoreAudio
import Foundation

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
