import SwiftUI

struct RecordingSessionRow: View {
    let session: RecordingSession
    let onTranscribe: () -> Void
    let onRetry: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                if let capturedAppName = session.capturedAppName {
                    Text("Recorded from \(capturedAppName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(dateText(session.createdAt)) • \(durationText(session.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .error = session.status, let errorMessage = session.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            statusAccessory
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case .done = session.status {
                onOpen()
            }
        }
    }

    @ViewBuilder
    private var statusAccessory: some View {
        switch session.status {
        case .recorded:
            Button("Transcribe", action: onTranscribe)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

        case .transcribing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .done:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .error:
            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
