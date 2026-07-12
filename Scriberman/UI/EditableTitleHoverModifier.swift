import SwiftUI

/// Shared hover treatment for editable session titles.
///
/// On hover it reveals a soft "card" affordance — an `.ultraThinMaterial`
/// background, a tint stroke, and a trailing pencil "Edit" icon — animated with a
/// gentle ease (no scale "jump"). It intentionally imposes neither a font nor a
/// text alignment so each caller keeps its own (centered vs leading, title2 vs
/// largeTitle).
struct EditableTitleHoverModifier: ViewModifier {
    @Binding var isHovering: Bool
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                if isHovering {
                    Label("Edit", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.trailing, 12)
                        .transition(.opacity)
                }
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
