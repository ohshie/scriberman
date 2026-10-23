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

                Picker("Mode", selection: Binding(
                    get: { appState.dictationModeSettings.mode },
                    set: { appState.dictationModeSettings.setMode($0) }
                )) {
                    Text("After release").tag(DictationMode.releaseTime)
                    Text("Live").tag(DictationMode.progressive)
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
        HotkeyLabel.string(for: combo, layout: .current)
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
