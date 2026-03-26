import SwiftUI

struct StudioView: View {
    @ObservedObject var viewModel: StudioViewModel

    var body: some View {
        VStack(spacing: 20) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            switch viewModel.recordingState {
            case .idle:
                Button("New Recording") {
                    Task { await viewModel.startRecording() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .recording(let duration, let level):
                VStack(spacing: 16) {
                    AudioLevelWaveform(level: level)
                    Text(durationText(duration))
                        .font(.title3)
                        .monospacedDigit()

                    Button("Stop") {
                        Task { await viewModel.stopRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

            case .stopped(_, let ctaSecondsRemaining):
                VStack(spacing: 12) {
                    Text("Saved to Jobs")
                        .font(.headline)

                    Button("Transcribe (\(ctaSecondsRemaining)s)") {
                        viewModel.transcribeCTASelected()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .task {
            await viewModel.refresh()
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct AudioLevelWaveform: View {
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<22, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor.opacity(0.25 + (Double(index) / 40.0)))
                    .frame(width: 6, height: barHeight(for: index))
            }
        }
        .frame(height: 72)
        .padding(.horizontal, 4)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalizedLevel = max(0, min(1, CGFloat(level)))
        let spread = abs(CGFloat(index - 11)) / 11
        let emphasis = max(0.18, 1 - (spread * 0.8))
        return 12 + (60 * normalizedLevel * emphasis)
    }
}
