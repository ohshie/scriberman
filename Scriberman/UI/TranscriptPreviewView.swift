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

                // The card opens the study view when clicked, and used to say so only by way of a
                // hover ring over a line reporting what it was withholding. The control is what
                // makes that path findable — and reachable by keyboard; the count keeps it company
                // rather than standing in its place.
                if let onTap {
                    HStack(spacing: 10) {
                        Button("Read full transcript", action: onTap)
                            .buttonStyle(.link)

                        if hasMore {
                            Text("\(blocks.count) sections")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if hasMore {
                    Text("\(blocks.count) sections")
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
