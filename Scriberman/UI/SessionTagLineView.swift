import SwiftUI

/// A recording's tags, named, on a line of their own beneath the duration.
///
/// Replaces `TagDotsView`, which showed colour in the row's leading column with no label — you could
/// see that a recording was tagged, not what with.
///
/// Each tag is a coloured dot followed by plain `Text`. The label being plain text is the point: the
/// list recolours it for selection exactly as it does the row's other captions, so the row never has
/// to know whether it is selected. Only the dot is a fixed colour, and it carries a hairline ring so
/// it stays distinct on both an unselected row and an accent-filled one.
struct SessionTagLineView: View {
    let tags: [RecordingTag]

    private static let dotSize: CGFloat = 7
    private static let dotLabelSpacing: CGFloat = 5
    private static let tagSpacing: CGFloat = 10

    /// The default tag is never named. Every untagged recording carries it, so naming it would mark
    /// most of the list with a label meaning "untagged" — which absence expresses better.
    private var namedTags: [RecordingTag] {
        tags.filter { !$0.isDefault }
    }

    var body: some View {
        if !namedTags.isEmpty {
            HStack(spacing: Self.tagSpacing) {
                ForEach(namedTags) { tag in
                    HStack(spacing: Self.dotLabelSpacing) {
                        Circle()
                            .fill(Color(tagHex: tag.colorHex))
                            .overlay(
                                Circle().strokeBorder(.background.opacity(0.6), lineWidth: 0.5)
                            )
                            .frame(width: Self.dotSize, height: Self.dotSize)

                        Text(tag.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    // Later tags give up space before earlier ones, so the first tag stays legible
                    // instead of every name being shortened equally.
                    .layoutPriority(priority(for: tag))
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func priority(for tag: RecordingTag) -> Double {
        guard let index = namedTags.firstIndex(where: { $0.id == tag.id }) else { return 0 }
        return Double(namedTags.count - index)
    }
}

extension Color {
    /// Builds a colour from a tag's `RRGGBB`. Falls back to the default tag colour rather than
    /// rendering nothing, so a bad value cannot make a dot invisible.
    init(tagHex hex: String) {
        let components = TagColor.components(fromHex: hex)
            ?? TagColor.components(fromHex: RecordingTag.Defaults.colorHex)!
        self.init(red: components.red, green: components.green, blue: components.blue)
    }
}
