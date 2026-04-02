import MarkdownUI
import SwiftUI

struct AITransformationPreviewCard: View {
    let transformation: AITransformation
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(transformation.promptName)
                .font(.title3.weight(.semibold))

            Markdown(transformation.resultText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
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
                .frame(maxHeight: 180, alignment: .top)
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
