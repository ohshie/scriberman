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
