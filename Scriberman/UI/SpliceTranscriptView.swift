import AppKit
import SwiftUI

struct SpliceTranscriptView: View {
    let editor: SpliceEditorViewModel
    let transcript: Transcript
    let player: AudioPlayerViewModel

    @State private var blocks: [TranscriptBlock] = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(editor.parts.enumerated()), id: \.element.id) { index, part in
                divider(at: index)
                let partBlocks = blocks.filter { editor.partIndex(at: Double($0.startTime)) == index }
                ForEach(Array(partBlocks.enumerated()), id: \.element.id) { offset, block in
                    if offset > 0, let point = gapPoint(from: partBlocks[offset - 1], to: block) {
                        SpliceGapButton { editor.addCut(near: point) }
                    }
                    TranscriptBlockView(
                        block: block,
                        isActive: player.currentTime >= Double(block.startTime) && player.currentTime < Double(block.endTime),
                        onTap: { player.seek(to: Double(block.startTime)); player.play() },
                        speakerEditing: nil,
                        showsAudioSource: transcript.isSinglePassOfMixedAudio != true
                    )
                    .opacity(part.isDropped ? 0.35 : 1)
                }
            }
        }
        .disabled(editor.isApplying)
        .onAppear { refreshBlocks() }
        .onChange(of: transcript) { refreshBlocks() }
    }

    private func refreshBlocks() {
        blocks = TranscriptGrouper.makeBlocks(from: transcript, breaksAt: editor.cutPoints)
    }

    private func divider(at index: Int) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(editor.parts[index].isDropped ? "Dropped" : editor.title(at: index)).lineLimit(1)
                // The part's length, as on its band.
                let range = editor.range(at: index)
                Text(TimeFormatter.displayFormat(seconds: Float(range.upperBound - range.lowerBound))).monospacedDigit()
                if index > 0 {
                    Button { editor.removeCut(editor.cuts[index - 1].id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove cut")
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color(index).opacity(0.12), in: Capsule())
            Rectangle().fill(color(index).opacity(0.5)).frame(height: 1)
        }
        .foregroundStyle(color(index))
        .padding(.top, 6)
    }

    private func color(_ index: Int) -> Color { editor.parts[index].isDropped ? .gray : SplicePartBand.color(index) }
    private func gapPoint(from earlier: TranscriptBlock, to later: TranscriptBlock) -> Double? {
        editor.cutPoints.first { point in
            point >= Double(earlier.endTime) && point <= Double(later.startTime) && !editor.cuts.contains { $0.time == point }
        }
    }
}

private struct SpliceGapButton: View {
    let onCut: () -> Void
    @State private var isHovering = false
    var body: some View {
        Button(action: onCut) {
            HStack {
                Rectangle().frame(height: 1)
                Image(systemName: "scissors").padding(3)
                Rectangle().frame(height: 1)
            }
            .foregroundStyle(.orange)
            .opacity(isHovering ? 1 : 0)
            .frame(maxWidth: .infinity, minHeight: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Cut here")
    }
}

/// C and Escape stay local to the editor's window. Text fields keep both keys.
struct SpliceKeyboardHandler: NSViewRepresentable {
    let isEditingText: Bool
    let isApplying: Bool
    let onCut: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) {
        view.handle = { event in
            guard !isApplying, !isEditingText, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
            if event.keyCode == 53 { onCancel(); return true }
            if event.charactersIgnoringModifiers?.lowercased() == "c" { onCut(); return true }
            return false
        }
    }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.removeMonitor() }

    final class KeyView: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window, window.isKeyWindow, event.window === window else { return event }
                return handle?(event) == true ? nil : event
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
