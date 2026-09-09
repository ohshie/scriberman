import SwiftUI

/// A recording's tags, named, on a line of their own beneath the duration.
///
/// Replaces `TagDotsView`, which showed colour in the row's leading column with no label — you could
/// see that a recording was tagged, not what with.
///
/// Each tag is a coloured dot and its name inside a capsule with the same glass treatment the
/// Pending status capsule uses.
///
/// The capsule is not decoration. Without a backdrop the chip sits directly on the list's selection
/// fill, and a bare dot plus text does not survive that — a tag coloured near the accent disappears
/// into it. Drawing the chip over the selection is also the only way to get this effect: a `List`
/// gives no way to cut its selection around a subview.
///
/// The name stays plain text rather than taking the tag's colour, because tag colours are random
/// and user-chosen; some would be unreadable as text. The colour lives in the dot and the capsule's
/// tint, where it cannot hurt legibility.
struct SessionTagLineView: View {
    let tags: [RecordingTag]

    private static let dotSize: CGFloat = 7
    private static let dotLabelSpacing: CGFloat = 5
    private static let tagSpacing: CGFloat = 6

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
                            .frame(width: Self.dotSize, height: Self.dotSize)

                        Text(tag.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    // The chip needs its own backdrop. Without one it sits directly on the list's
                    // selection fill, and a plain dot plus text does not survive that — a tag
                    // coloured near the accent disappears into it. The same treatment the Pending
                    // capsule already uses, so the chip reads over whatever is behind it.
                    .glassEffect(.regular, in: Capsule())
                    .tint(Color(tagHex: tag.colorHex))
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
