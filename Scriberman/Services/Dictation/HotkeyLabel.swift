import Carbon

/// Translates virtual key codes to the characters a keyboard layout produces, with no modifiers applied.
struct KeyboardLayout {
    private let layoutData: Data

    private init?(inputSource: TISInputSource) {
        guard let pointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    static var current: KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return KeyboardLayout(inputSource: source)
    }

    static func installed(id: String) -> KeyboardLayout? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first
        else {
            return nil
        }
        return KeyboardLayout(inputSource: source)
    }

    func character(for keyCode: UInt32) -> String? {
        layoutData.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            let string = String(utf16CodeUnits: chars, count: length)
            // Keys like Home or keypad Enter translate to control characters.
            guard !string.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                return nil
            }
            return string
        }
    }
}

enum HotkeyLabel {
    static func string(for combo: HotkeyCombo, layout: KeyboardLayout?) -> String {
        var parts: [String] = []
        let mods = combo.carbonModifiers
        if mods & UInt32(controlKey) != 0 { parts.append("⌃") }
        if mods & UInt32(optionKey) != 0 { parts.append("⌥") }
        if mods & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if mods & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyName(for: combo.keyCode, layout: layout))
        return parts.joined()
    }

    private static func keyName(for keyCode: UInt32, layout: KeyboardLayout?) -> String {
        if let name = fixedNames[Int(keyCode)] { return name }
        guard let character = layout?.character(for: keyCode) else { return "Key\(keyCode)" }
        let uppercased = character.uppercased()
        // Keep characters whose uppercase form is longer, such as ß.
        return uppercased.count == character.count ? uppercased : character
    }

    private static let fixedNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Delete: "⌫",
        kVK_Escape: "⎋",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Space: "Space",
    ]
}
