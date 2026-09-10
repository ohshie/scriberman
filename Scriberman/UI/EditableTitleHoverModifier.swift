import SwiftUI

/// Shared hover treatment for editable session titles.
///
/// The pencil is present at rest, faintly. A cue that appears only under the pointer tells nobody
/// anything, and a session named after its own timestamp is the title most worth renaming — so the
/// one field a user would want to change was the one the app never offered to change.
///
/// On hover it reveals the rest of the affordance — an `.ultraThinMaterial` background, a tint
/// stroke, and the pencil at full strength — animated with a gentle ease (no scale "jump"). It
/// intentionally imposes neither a font nor a text alignment so each caller keeps its own (centered
/// vs leading, title2 vs largeTitle).
struct EditableTitleHoverModifier: ViewModifier {
    @Binding var isHovering: Bool
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                Label("Edit", systemImage: "pencil")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    // Quiet at rest, so the title still reads as a title; the tint is the hover.
                    .foregroundStyle(isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .opacity(isHovering ? 1 : 0.45)
                    .padding(.trailing, 12)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(isHovering ? 1 : 0)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.tint.opacity(isHovering ? 0.35 : 0), lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(.easeInOut(duration: 0.2), value: isHovering)
    }
}

extension View {
    /// Applies the shared editable-title hover affordance driven by `isHovering`.
    func editableTitleHover(isHovering: Binding<Bool>, cornerRadius: CGFloat = 12) -> some View {
        modifier(EditableTitleHoverModifier(isHovering: isHovering, cornerRadius: cornerRadius))
    }
}
