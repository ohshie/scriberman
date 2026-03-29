import SwiftUI

struct TranscriptPreviewView: View {
    let blocks: [TranscriptBlock]
    let previewLimit: Int
    let onTap: (() -> Void)?

    @State private var isHovering = false

    init(blocks: [TranscriptBlock], previewLimit: Int = 4, onTap: (() -> Void)? = nil) {
        self.blocks = blocks
        self.previewLimit = previewLimit
        self.onTap = onTap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcript")
                .font(.title3.weight(.semibold))

            if previewBlocks.isEmpty {
                Text("No transcript available.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(previewBlocks) { block in
                    TranscriptBlockView(block: block)
                }

                if hasMore {
                    Text("Showing \(previewBlocks.count) of \(blocks.count) sections")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            onTap?()
        }
        .onHover { hovering in
            guard onTap != nil else {
                isHovering = false
                return
            }
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

    private var previewBlocks: [TranscriptBlock] {
        Array(blocks.prefix(previewLimit))
    }

    private var hasMore: Bool {
        blocks.count > previewBlocks.count
    }
}
