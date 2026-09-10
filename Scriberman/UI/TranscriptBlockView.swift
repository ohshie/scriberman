import SwiftUI

struct TranscriptBlockView: View {
    let block: TranscriptBlock
    let isActive: Bool
    let searchRanges: [Range<String.Index>]
    let activeSearchRange: Range<String.Index>?
    let onTap: () -> Void
    var onSpeakerRename: ((String) -> Void)? = nil

    @State private var isEditingSpeaker = false
    @State private var speakerNameDraft = ""

    init(
        block: TranscriptBlock,
        isActive: Bool = false,
        searchRanges: [Range<String.Index>] = [],
        activeSearchRange: Range<String.Index>? = nil,
        onTap: @escaping () -> Void = {},
        onSpeakerRename: ((String) -> Void)? = nil
    ) {
        self.block = block
        self.isActive = isActive
        self.searchRanges = searchRanges
        self.activeSearchRange = activeSearchRange
        self.onTap = onTap
        self.onSpeakerRename = onSpeakerRename
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
    }

    /// The speaker's dot and name, which double as the rename control.
    @ViewBuilder
    private var speakerIdentity: some View {
        Circle()
            .fill(speakerColor)
            .frame(width: 10, height: 10)

        if isEditingSpeaker {
            TextField("Speaker Name", text: $speakerNameDraft)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(speakerColor)
                .onSubmit {
                    commitRename()
                }
        } else {
            Text(block.speaker.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(speakerColor)
                .onTapGesture {
                    if onSpeakerRename != nil {
                        speakerNameDraft = block.speaker.label
                        isEditingSpeaker = true
                    }
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

    private func commitRename() {
        let trimmed = speakerNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != block.speaker.label {
            onSpeakerRename?(trimmed)
        }
        isEditingSpeaker = false
    }
}

private extension Color {
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
