import SwiftUI

/// Shared concentric "hero" button: an outer stroked ring around an inner filled
/// shape, with a caption below. Used for the New Session Record button
/// (`.circle`) and the in-progress Stop button (`.roundedSquare`).
///
/// Hover feedback is built in: while enabled and hovered the inner shape scales
/// up slightly and the ring brightens.
struct HeroCircleButton: View {
    enum InnerShape {
        case circle
        case roundedSquare
    }

    let innerShape: InnerShape
    let tint: Color
    let caption: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    private var isActive: Bool { isHovering && isEnabled }

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .strokeBorder(tint.opacity(isActive ? 0.85 : 0.5), lineWidth: 1.5)
                        .frame(width: 62, height: 62)

                    innerShapeView
                        .foregroundStyle(tint)
                        .scaleEffect(isActive ? 1.06 : 1.0)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .accessibilityLabel(caption)

            Text(caption)
                .font(.callout.weight(.medium))
                .foregroundStyle(isEnabled ? .primary : .secondary)
        }
    }

    @ViewBuilder
    private var innerShapeView: some View {
        switch innerShape {
        case .circle:
            Circle()
                .fill(tint)
                .frame(width: 46, height: 46)
        case .roundedSquare:
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint)
                .frame(width: 30, height: 30)
        }
    }
}
