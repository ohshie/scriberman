import SwiftUI

struct TranscriptStudyView: View {
    let session: any TranscribableSession
    let transcript: Transcript

    @Environment(\.dismiss) private var dismiss
    @State private var showRawMarkdown = false

    private let markdownRenderer = MarkdownRenderer()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showRawMarkdown {
                        Text(rawMarkdown)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else if blocks.isEmpty {
                        Text("No transcript available.")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(blocks) { block in
                                TranscriptBlockView(block: block)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("Study Transcript")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                Toggle(isOn: $showRawMarkdown) {
                    Text("Raw Markdown")
                        .font(.subheadline.weight(.medium))
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }

    private var blocks: [TranscriptBlock] {
        TranscriptGrouper.makeBlocks(from: transcript)
    }

    private var rawMarkdown: String {
        markdownRenderer.renderMarkdown(session: session, transcript: transcript)
    }
}
