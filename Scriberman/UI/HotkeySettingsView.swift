import Carbon
import SwiftUI

struct HotkeySettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isRecordingHotkey = false
    @State private var validationMessage: String?

    private var settings: DictationHotkeySettings { appState.dictationHotkeySettings }
    private var isAccessibilityGranted: Bool { TextInjector().isAccessibilityGranted }

    var body: some View {
        Form {
            Section("Dictation Hotkey") {
                Text("Hold the hotkey and speak — transcribed text is typed into the active field.")
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Hotkey")
                    Spacer()
                    HotkeyRecorderButton(
                        combo: settings.combo,
                        isRecording: $isRecordingHotkey,
                        onCommit: { newCombo in
                            if !settings.setCombo(newCombo) {
                                validationMessage = "That shortcut conflicts with a system shortcut. Please choose a different one."
                            } else {
                                validationMessage = nil
                                appState.hotkeyRegistrar.unregister()
                                appState.hotkeyRegistrar.register(combo: newCombo)
                            }
                        }
                    )
                }

                if let msg = validationMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Microphone") {
                LabeledContent("Source") {
                    Text(currentMicrophoneName)
                }
                Text("Dictation uses the microphone currently selected in the menu bar recording menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Accessibility") {
                if isAccessibilityGranted {
                    Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Accessibility access required", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Scriberman needs Accessibility permission to type transcribed text into other apps. Without it, text is copied to the clipboard instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            )
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var currentMicrophoneName: String {
        guard let uid = appState.menuBarSettings.lastUsedMicUID else {
            return "System Default"
        }

        return appState.audioDeviceService.availableDevices.first(where: { $0.uid == uid })?.name ?? "System Default"
    }
}

// MARK: - Hotkey Recorder

private struct HotkeyRecorderButton: View {
    let combo: HotkeyCombo
    @Binding var isRecording: Bool
    let onCommit: (HotkeyCombo) -> Void

    var body: some View {
        Button(action: { isRecording = true }) {
            Text(isRecording ? "Press keys…" : comboLabel)
                .frame(minWidth: 120)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isRecording ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .background(HotkeyCapture(isRecording: $isRecording, onCommit: onCommit))
    }

    private var comboLabel: String {
        var parts: [String] = []
        let mods = combo.carbonModifiers
        if mods & UInt32(controlKey) != 0 { parts.append("⌃") }
        if mods & UInt32(optionKey) != 0 { parts.append("⌥") }
        if mods & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if mods & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyName(for: combo.keyCode))
        return parts.joined()
    }

    private func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        default: return "Key\(keyCode)"
        }
    }
}

// Transparent NSView that handles key capture for the hotkey recorder.
private struct HotkeyCapture: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCommit: (HotkeyCombo) -> Void

    func makeNSView(context: Context) -> HotkeyCaptureView {
        let view = HotkeyCaptureView()
        view.onCommit = onCommit
        view.onCancel = { isRecording = false }
        return view
    }

    func updateNSView(_ nsView: HotkeyCaptureView, context: Context) {
        if isRecording {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class HotkeyCaptureView: NSView {
    var onCommit: ((HotkeyCombo) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) != [] else {
            // Escape cancels recording
            if event.keyCode == UInt16(kVK_Escape) {
                onCancel?()
            }
            return
        }

        var carbonMods: UInt32 = 0
        if event.modifierFlags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { carbonMods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { carbonMods |= UInt32(controlKey) }

        let combo = HotkeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods)
        onCommit?(combo)
        onCancel?() // exit recording mode after capturing
    }
}
