import SwiftUI

/// A recording's tags, as one coloured dot each, centred in the row's leading slot.
///
/// Replaces the source glyph on recording rows. Nothing is lost: the source is already printed as
/// caption text on the line below. A recording always carries at least one tag, so this is never
/// empty in practice — the empty case is handled anyway rather than trapped on.
///
/// Three dots are arranged as a triangle. Centring one and two keeps them visually balanced; the
/// cost is that dots move as tags are added, which reads better than fixed slots that leave a
/// single dot high and off-centre.
struct TagDotsView: View {
    let colors: [Color]

    /// Matches the source glyph this replaces.
    static let slotSize: CGFloat = 24
    private static let dotSize: CGFloat = 8
    private static let spacing: CGFloat = 2

    var body: some View {
        ZStack {
            switch colors.count {
            case 0:
                EmptyView()
            case 1:
                dot(colors[0])
            case 2:
                HStack(spacing: Self.spacing) {
                    dot(colors[0])
                    dot(colors[1])
                }
            default:
                VStack(spacing: Self.spacing) {
                    dot(colors[0])
                    HStack(spacing: Self.spacing) {
                        dot(colors[1])
                        dot(colors[2])
                    }
                }
            }
        }
        .frame(width: Self.slotSize, height: Self.slotSize, alignment: .center)
        .accessibilityHidden(true)
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: Self.dotSize, height: Self.dotSize)
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
