import SwiftUI

struct TranscriptStudyView: View {
    let session: any TranscribableSession
    let transcript: Transcript
    let showRawMarkdownToggle: Bool

    @State private var showRawMarkdown = false

    private let markdownRenderer = MarkdownRenderer()

    init(
        session: any TranscribableSession,
        transcript: Transcript,
        showRawMarkdownToggle: Bool = true
    ) {
        self.session = session
        self.transcript = transcript
        self.showRawMarkdownToggle = showRawMarkdownToggle
    }

    var body: some View {
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
        .safeAreaInset(edge: .top) {
            if showRawMarkdownToggle {
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

    @ToolbarContentBuilder
    static func toolbarActions(
        onCopy: @escaping () -> Void,
        onExport: @escaping () -> Void
    ) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                onCopy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                onExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
    }
}
