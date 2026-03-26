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
                    WaveformView(level: .constant(level))
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
