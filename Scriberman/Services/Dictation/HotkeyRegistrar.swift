import Carbon
import Foundation

struct HotkeyCombo: Equatable, Hashable, Codable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    static let defaultDictation = HotkeyCombo(
        keyCode: UInt32(kVK_ANSI_D),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    var isValid: Bool {
        !HotkeyRegistrar.denylist.contains(self)
    }
}

// File-scope C-compatible callback — receives `HotkeyRegistrar` via userData.
private func hotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }
    let registrar = Unmanaged<HotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    let kind = GetEventKind(event)
    if kind == OSType(kEventHotKeyPressed) {
        let handler = registrar.onKeyDown
        DispatchQueue.main.async { handler?() }
    } else if kind == OSType(kEventHotKeyReleased) {
        let handler = registrar.onKeyUp
        DispatchQueue.main.async { handler?() }
    }
    return noErr
}

final class HotkeyRegistrar {
    var onKeyDown: (@Sendable () -> Void)?
    var onKeyUp: (@Sendable () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var registeredCombo: HotkeyCombo?

    // Combos that must not be used as dictation hotkeys (⌘C, ⌘V, ⌘Q, etc.)
    static let denylist: Set<HotkeyCombo> = {
        let cmd = UInt32(cmdKey)
        let cmdShift = UInt32(cmdKey | shiftKey)
        // US key codes for common system shortcuts
        let cmdKeyCodes: [UInt32] = [
            UInt32(kVK_ANSI_C),   // ⌘C
            UInt32(kVK_ANSI_V),   // ⌘V
            UInt32(kVK_ANSI_X),   // ⌘X
            UInt32(kVK_ANSI_Z),   // ⌘Z
            UInt32(kVK_ANSI_A),   // ⌘A
            UInt32(kVK_ANSI_Q),   // ⌘Q
            UInt32(kVK_ANSI_W),   // ⌘W
            UInt32(kVK_ANSI_H),   // ⌘H
            UInt32(kVK_ANSI_M),   // ⌘M
            UInt32(kVK_Space),    // ⌘Space
            UInt32(kVK_Tab),      // ⌘Tab
        ]
        // Carbon virtual key codes for function keys are not sequential.
        let functionKeyCodes: [UInt32] = [
            UInt32(kVK_F1),
            UInt32(kVK_F2),
            UInt32(kVK_F3),
            UInt32(kVK_F4),
            UInt32(kVK_F5),
            UInt32(kVK_F6),
            UInt32(kVK_F7),
            UInt32(kVK_F8),
            UInt32(kVK_F9),
            UInt32(kVK_F10),
            UInt32(kVK_F11),
            UInt32(kVK_F12),
            UInt32(kVK_F13),
            UInt32(kVK_F14),
            UInt32(kVK_F15),
            UInt32(kVK_F16),
            UInt32(kVK_F17),
            UInt32(kVK_F18),
            UInt32(kVK_F19),
            UInt32(kVK_F20),
        ]
        var set: Set<HotkeyCombo> = []
        for keyCode in cmdKeyCodes {
            set.insert(HotkeyCombo(keyCode: keyCode, carbonModifiers: cmd))
        }
        for keyCode in functionKeyCodes {
            set.insert(HotkeyCombo(keyCode: keyCode, carbonModifiers: 0))
            set.insert(HotkeyCombo(keyCode: keyCode, carbonModifiers: cmd))
        }
        return set
    }()

    func register(combo: HotkeyCombo) {
        guard combo.isValid else { return }
        unregister()

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = FourCharCode(0x5344_4354) // "SDCT"
        hotKeyID.id = 1

        var keyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &keyRef
        )
        guard status == noErr else { return }
        hotKeyRef = keyRef

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyReleased)),
        ]
        var handlerRef: EventHandlerRef?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            2,
            &eventTypes,
            selfPtr,
            &handlerRef
        )
        eventHandlerRef = handlerRef
        registeredCombo = combo
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        registeredCombo = nil
    }

    deinit {
        unregister()
    }
}
