import SwiftUI

struct ImportedSessionRow: View {
    let session: ImportedSession
    let onRetry: () -> Void
    /// The line a search matched inside this session's transcript, when it was reached by search.
    var searchSnippet: SessionSearchSnippet? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            sourceGlyph

            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)

                // The timestamp shares this line rather than taking one of its own. Its trailing
                // edge is the text column's, which ends where the accessory begins — and accessory
                // width varies with status, so timestamps are not aligned down the list. Accepted:
                // the rows sitting furthest from the edge are the ones carrying a button.
                HStack(spacing: 6) {
                    Text(sourceName)
                    Text("•")
                    Text(durationText(session.duration))
                    Spacer(minLength: 8)
                    Text(JobsViewModel.relativeTimestampText(for: session.createdAt))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let searchSnippet {
                    SearchSnippetView(snippet: searchSnippet)
                }
            }
            // Fills, so the timestamp's trailing alignment has an edge to resolve against. This is
            // also what puts the accessory column against the row's right side without a Spacer.
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                if !statusIndicatorBelongsInAccessory {
                    statusIndicator
                }
                accessory
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var sourceGlyph: some View {
        Image(systemName: "mic.fill")
            .font(.title3)
            .foregroundStyle(.tint)
            .frame(width: 24, height: 24, alignment: .center)
            .accessibilityHidden(true)
    }

    private var sourceName: String {
        session.originalFileName
    }

    @ViewBuilder
    private var accessory: some View {
        switch session.status {
        case .recorded, .recording:
            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)

        case .converting, .transcribing, .retranscribing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Working")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .done:
            statusIndicator

        case .error:
            HStack(spacing: 6) {
                statusIndicator
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var statusIndicatorBelongsInAccessory: Bool {
        switch session.status {
        case .done, .error:
            return true
        case .recorded, .recording, .converting, .transcribing, .retranscribing:
            return false
        }
    }

    private var statusIndicator: some View {
        StatusTagView(status: session.status)
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}
