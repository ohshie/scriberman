import SwiftUI

struct RecordingSessionRow: View {
    let session: RecordingSession
    let onTranscribe: () -> Void
    let onRetry: () -> Void
    @State private var isPulsing = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            sourceGlyph

            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(sourceName)
                    Text("•")
                    Text(durationText(session.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Text(JobsViewModel.relativeTimestampText(for: session.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                StatusTagView(status: session.status)
                accessory
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var sourceGlyph: some View {
        Image(systemName: session.capturedAppName == nil ? "mic.fill" : "app.fill")
            .font(.title3)
            .foregroundStyle(.tint)
            .frame(width: 24, height: 24, alignment: .center)
            .accessibilityHidden(true)
    }

    private var sourceName: String {
        session.capturedAppName ?? "Microphone"
    }

    @ViewBuilder
    private var accessory: some View {
        switch session.status {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(isPulsing ? 1.0 : 0.35)
                .animation(
                    .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                    value: isPulsing
                )
                .onAppear {
                    isPulsing = true
                }

        case .recorded:
            Button("Transcribe", action: onTranscribe)
                .buttonStyle(.borderedProminent)
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
            EmptyView()

        case .error:
            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
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
