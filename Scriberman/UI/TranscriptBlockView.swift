import AppKit
import SwiftUI

struct TranscriptBlockView: View {
    let block: TranscriptBlock
    let isActive: Bool
    let searchRanges: [Range<String.Index>]
    let activeSearchRange: Range<String.Index>?
    let onTap: () -> Void
    var speakerEditing: SpeakerEditing?

    /// What a block of a saved transcript needs to edit its speaker. The caller owns which block is
    /// renaming, so a click on another block can close the field.
    struct SpeakerEditing {
        var isRenaming: Bool
        /// Stored profiles the rename field suggests.
        var profiles: [SpeakerProfileSnapshot]
        /// The transcript's other speakers, with their display colours, for "assign this block to".
        var otherSpeakers: [TranscriptSpeaker]
        var onBeginRename: () -> Void
        var onEndRename: () -> Void
        var onRename: (String) -> Void
        /// Gives this block to the speaker with the ID, or to a new speaker for `nil`.
        var onAssign: (String?) -> Void
    }

    init(
        block: TranscriptBlock,
        isActive: Bool = false,
        searchRanges: [Range<String.Index>] = [],
        activeSearchRange: Range<String.Index>? = nil,
        onTap: @escaping () -> Void = {},
        speakerEditing: SpeakerEditing? = nil
    ) {
        self.block = block
        self.isActive = isActive
        self.searchRanges = searchRanges
        self.activeSearchRange = activeSearchRange
        self.onTap = onTap
        self.speakerEditing = speakerEditing
    }

    var body: some View {
        TranscriptRowView(
            timeText: startTimeText,
            audioSource: block.audioSource,
            copyText: block.text,
            isActive: isActive,
            activeColor: speakerColor
        ) {
            speakerIdentity
        } content: {
            transcriptText
        }
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            if let speakerEditing {
                blockMenu(speakerEditing)
            }
        }
    }

    /// The speaker's dot and name, which double as the rename control.
    @ViewBuilder
    private var speakerIdentity: some View {
        Circle()
            .fill(speakerColor)
            .frame(width: 10, height: 10)

        if let speakerEditing, speakerEditing.isRenaming {
            SpeakerNameField(
                name: block.speaker.label,
                profiles: speakerEditing.profiles,
                color: speakerColor,
                onCommit: { name in
                    speakerEditing.onRename(name)
                    speakerEditing.onEndRename()
                },
                onCancel: speakerEditing.onEndRename
            )
        } else {
            Text(block.speaker.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(speakerColor)
                .onTapGesture {
                    speakerEditing?.onBeginRename()
                }

            if let speakerEditing {
                Button {
                    speakerEditing.onBeginRename()
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Rename speaker")
                .accessibilityLabel("Rename speaker")
            }
        }
    }

    @ViewBuilder
    private func blockMenu(_ speakerEditing: SpeakerEditing) -> some View {
        Button("Copy") {
            copyTranscriptText(block.text)
        }
        Divider()
        Button("rename speaker") {
            speakerEditing.onBeginRename()
        }
        Menu("assign this block to") {
            ForEach(speakerEditing.otherSpeakers) { speaker in
                Button {
                    speakerEditing.onAssign(speaker.id)
                } label: {
                    Label {
                        Text(speaker.label)
                    } icon: {
                        Image(nsImage: SpeakerDotImage.make(hex: speaker.colorHex))
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            Divider()
            Button("new speaker") {
                speakerEditing.onAssign(nil)
            }
        }
    }

    @ViewBuilder
    private var transcriptText: some View {
        if searchRanges.isEmpty {
            Text(block.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(highlightedText())
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var startTimeText: String {
        // The block's start, and only that. Its end is the next block's start, one line below, so
        // showing both states the same boundary twice — and millisecond precision serves a subtitle
        // tool, not someone reading. The export still writes full precision.
        TimeFormatter.displayFormat(seconds: block.startTime)
    }

    private var speakerColor: Color {
        Color(hex: block.speaker.colorHex) ?? .accentColor
    }

    private func highlightedText() -> AttributedString {
        var attributedText = AttributedString(block.text)

        for range in searchRanges {
            guard
                let lowerBound = AttributedString.Index(range.lowerBound, within: attributedText),
                let upperBound = AttributedString.Index(range.upperBound, within: attributedText)
            else {
                continue
            }

            attributedText[lowerBound..<upperBound].backgroundColor = .yellow.opacity(0.25)
        }

        if let activeSearchRange,
           let lowerBound = AttributedString.Index(activeSearchRange.lowerBound, within: attributedText),
           let upperBound = AttributedString.Index(activeSearchRange.upperBound, within: attributedText) {
            attributedText[lowerBound..<upperBound].backgroundColor = .orange.opacity(0.45)
        }

        return attributedText
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6, let rgb = Int(value, radix: 16) else {
            return nil
        }

        let red = Double((rgb >> 16) & 0xFF) / 255.0
        let green = Double((rgb >> 8) & 0xFF) / 255.0
        let blue = Double(rgb & 0xFF) / 255.0

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }
}

/// A speaker's colour dot as a non-template image, so a menu draws it in colour.
enum SpeakerDotImage {
    static func make(hex: String, diameter: CGFloat = 10) -> NSImage {
        let color = NSColor(Color(hex: hex) ?? .accentColor)
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
