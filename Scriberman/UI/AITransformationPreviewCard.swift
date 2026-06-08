import MarkdownUI
import SwiftUI

struct AITransformationPreviewCard: View {
    let transformation: AITransformation
    let onTap: () -> Void
    let onCopy: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(transformation.promptName)
                    .font(.title3.weight(.semibold))

                Spacer(minLength: 0)

                Button {
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
            }

            Markdown(transformation.resultText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 180, alignment: .top)
                .mask(alignment: .bottom) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.82),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .clipped()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            onTap()
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if isHovering {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.tint.opacity(0.35), lineWidth: 1.5)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}
