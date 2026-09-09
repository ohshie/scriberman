import SwiftUI

struct RecordingSessionRow: View {
    let session: RecordingSession
    let onTranscribe: () -> Void
    let onRetry: () -> Void
    @State private var isPulsing = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            tagDots

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

                if session.screenCaptureWarning != nil {
                    Label("Screen recording failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // A caveat, not a failure: capture dropped mid-recording and came back, so the
                // audio contains an interval of silence. Deliberately not the `.error` treatment —
                // the recording succeeded and its audio is usable. Independent of the screen
                // warning above, so a recording that hit both shows both.
                if session.wasCaptureInterrupted {
                    Label("Capture was interrupted and resumed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // One line for both conditions: a source that stopped partway and a write that
                // failed mean the same thing to a listener — an interval of the recording is
                // silence. Like the caveats above, not the `.error` treatment: the recording
                // succeeded and its audio is usable.
                if session.hasIncompleteCapturedAudio {
                    Label("Recorded, but some segments may be missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 12)

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

    /// Tag dots stand where the source glyph used to. A recording always carries at least one tag,
    /// so the glyph was unreachable and has been removed rather than left behind a dead branch.
    @ViewBuilder
    private var tagDots: some View {
        TagDotsView(colors: session.tags.prefix(3).map { Color(tagHex: $0.colorHex) })
    }

    private var sourceName: String {
        session.capturedAppName ?? "Microphone"
    }

    @ViewBuilder
    private var accessory: some View {
        switch session.status {
        case .recording:
            Circle()
                .fill(Color("StatusRecordingColor"))
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
        case .recording, .recorded, .converting, .transcribing, .retranscribing:
            return false
        }
    }

    private var statusIndicator: some View {
        StatusTagView(
            status: session.status,
            hasTranscript: session.transcriptData != nil,
            hasAITransformation: session.aiTransformationsData != nil
        )
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
