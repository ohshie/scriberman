import SwiftUI

struct TranscriptPreviewView: View {
    let blocks: [TranscriptBlock]
    let previewLimit: Int

    init(blocks: [TranscriptBlock], previewLimit: Int = 4) {
        self.blocks = blocks
        self.previewLimit = previewLimit
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var previewBlocks: [TranscriptBlock] {
        Array(blocks.prefix(previewLimit))
    }

    private var hasMore: Bool {
        blocks.count > previewBlocks.count
    }
}
