import Carbon
import Foundation
import Testing
@testable import Scriberman

@MainActor
struct HotkeyLabelTests {
    private func layout(_ id: String) throws -> KeyboardLayout {
        try #require(KeyboardLayout.installed(id: id))
    }

    private func label(_ keyCode: Int, _ modifiers: Int, layout id: String = "com.apple.keylayout.US") throws -> String {
        let combo = HotkeyCombo(keyCode: UInt32(keyCode), carbonModifiers: UInt32(modifiers))
        return HotkeyLabel.string(for: combo, layout: try layout(id))
    }

    @Test("Letters show the uppercase character")
    func letters() throws {
        #expect(try label(kVK_ANSI_D, cmdKey | shiftKey) == "⇧⌘D")
        #expect(try label(kVK_ANSI_A, controlKey) == "⌃A")
    }

    @Test("Option+1 shows ⌥1")
    func digits() throws {
        #expect(try label(kVK_ANSI_1, optionKey) == "⌥1")
        #expect(try label(kVK_ANSI_0, cmdKey) == "⌘0")
    }

    @Test("Control+F5 shows ⌃F5")
    func functionKeys() throws {
        #expect(try label(kVK_F5, controlKey) == "⌃F5")
        #expect(try label(kVK_F1, optionKey) == "⌥F1")
        #expect(try label(kVK_F12, cmdKey) == "⌘F12")
    }

    @Test("Arrows and keys without a character use fixed names")
    func fixedNames() throws {
        #expect(try label(kVK_LeftArrow, optionKey) == "⌥←")
        #expect(try label(kVK_RightArrow, optionKey) == "⌥→")
        #expect(try label(kVK_UpArrow, optionKey) == "⌥↑")
        #expect(try label(kVK_DownArrow, optionKey) == "⌥↓")
        #expect(try label(kVK_Delete, optionKey) == "⌥⌫")
        #expect(try label(kVK_Escape, optionKey) == "⌥⎋")
        #expect(try label(kVK_Return, optionKey) == "⌥↩")
        #expect(try label(kVK_Tab, optionKey) == "⌥⇥")
        #expect(try label(kVK_Space, optionKey) == "⌥Space")
    }

    @Test("Punctuation shows the unshifted character")
    func punctuation() throws {
        #expect(try label(kVK_ANSI_Minus, cmdKey | shiftKey) == "⇧⌘-")
        #expect(try label(kVK_ANSI_Slash, optionKey) == "⌥/")
        #expect(try label(kVK_ANSI_Semicolon, controlKey) == "⌃;")
    }

    @Test("The character follows the keyboard layout")
    func nonUSLayout() throws {
        #expect(try label(kVK_ANSI_Y, optionKey, layout: "com.apple.keylayout.German") == "⌥Z")
    }

    @Test("A combination saved before the change displays correctly")
    func savedCombination() throws {
        let defaults = UserDefaults(suiteName: "HotkeyLabelTests-\(UUID().uuidString)")!
        let stored = #"{"keyCode":\#(kVK_ANSI_1),"carbonModifiers":\#(optionKey)}"#
        defaults.set(Data(stored.utf8), forKey: "dictationHotkeyCombo")

        let settings = DictationHotkeySettings(defaults: defaults)

        #expect(HotkeyLabel.string(for: settings.combo, layout: try layout("com.apple.keylayout.US")) == "⌥1")
    }
}
