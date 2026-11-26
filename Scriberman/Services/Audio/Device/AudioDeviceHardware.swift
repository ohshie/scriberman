import CoreAudio
import Foundation

private let audioObjectSystemObjectID = AudioObjectID(kAudioObjectSystemObject)

protocol AudioDeviceHardwareProviding {
    func allDeviceIDs() throws -> [AudioDeviceID]
    /// How many channels the device can capture. Zero means it is not a microphone.
    func inputChannelCount(deviceID: AudioDeviceID) -> Int
    func deviceUID(deviceID: AudioDeviceID) -> String?
    func deviceName(deviceID: AudioDeviceID) -> String?
    func defaultInputDeviceID() -> AudioDeviceID?
    /// `kAudioDevicePropertyDeviceIsAlive`. False once the device is unusable, or when it is gone.
    func isAlive(deviceID: AudioDeviceID) -> Bool
    /// An aggregate device whose composition has `kAudioAggregateDeviceIsPrivateKey` set: visible
    /// only to the process that created it. macOS creates one, `CADefaultDeviceAggregate-<pid>-<n>`,
    /// for this application's own audio engine.
    func isPrivateAggregate(deviceID: AudioDeviceID) -> Bool
}

extension AudioDeviceHardwareProviding {
    /// Whether the device can be offered and captured as a microphone. Device enumeration and
    /// capture targeting both decide with this, so a device is never targeted that the list hides.
    func isUsableMicrophone(deviceID: AudioDeviceID) -> Bool {
        inputChannelCount(deviceID: deviceID) > 0
            && isAlive(deviceID: deviceID)
            && !isPrivateAggregate(deviceID: deviceID)
    }
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

    /// How many channels the device can capture, summed across its input buffers.
    ///
    /// Channels rather than streams, and input scope rather than global. The previous check asked
    /// `kAudioDevicePropertyStreams` in **global** scope and passed a direction as qualifier data,
    /// which that property ignores — so it counted every stream the device owned, in both
    /// directions, and answered "has any stream at all". Built-in speakers passed it, were offered
    /// as a microphone, and a recording that selected them captured nothing for its whole duration.
    ///
    /// Channel count rather than stream count because a device can expose an input stream carrying
    /// no channels — an aggregate device mid-configuration does exactly that, and this application
    /// builds aggregate devices.
    func inputChannelCount(deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else {
            return 0
        }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, buffer) == noErr else {
            return 0
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
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

    func isAlive(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &isAlive)
        return status == noErr && isAlive != 0
    }

    func isPrivateAggregate(deviceID: AudioDeviceID) -> Bool {
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transportType) == noErr,
              transportType == kAudioDeviceTransportTypeAggregate
        else {
            return false
        }

        var compositionAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var composition: CFDictionary?
        var compositionSize = UInt32(MemoryLayout<CFDictionary?>.size)
        let status = withUnsafeMutablePointer(to: &composition) { compositionPointer in
            AudioObjectGetPropertyData(deviceID, &compositionAddress, 0, nil, &compositionSize, compositionPointer)
        }
        guard status == noErr,
              let composition = composition as? [String: Any],
              let isPrivate = composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber
        else {
            return false
        }
        return isPrivate.intValue != 0
    }
}
