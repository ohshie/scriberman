import SwiftUI

struct AudioPlayerBar: View {
    let viewModel: AudioPlayerViewModel
    let sessionHasAudio: Bool
    let mixdownURL: String?

    @State private var previousMixdownURL: String?

    var body: some View {
        Group {
            if sessionHasAudio {
                HStack(spacing: 12) {
                    if viewModel.isReady == false {
                        loadingContent
                    } else {
                        readyContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.85), in: Capsule())
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .onAppear {
            previousMixdownURL = mixdownURL
        }
        .onChange(of: mixdownURL) {
            let oldValue = previousMixdownURL
            previousMixdownURL = mixdownURL

            guard oldValue == nil,
                  let mixdownURL,
                  mixdownURL.isEmpty == false
            else {
                return
            }

            viewModel.load(url: URL(fileURLWithPath: mixdownURL))
        }
    }

    private var loadingContent: some View {
        HStack(spacing: 10) {
            ProgressView()

            Text("Getting recording ready…")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private var readyContent: some View {
        HStack(spacing: 12) {
            Button {
                if viewModel.isPlaying {
                    viewModel.pause()
                } else {
                    viewModel.play()
                }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { viewModel.currentTime },
                    set: { viewModel.currentTime = $0 }
                ),
                in: 0...(viewModel.duration > 0 ? viewModel.duration : 1),
                onEditingChanged: { isEditing in
                    if isEditing {
                        viewModel.isScrubbing = true
                    } else {
                        viewModel.seek(to: viewModel.currentTime)
                        viewModel.isScrubbing = false
                    }
                }
            )
            .disabled(viewModel.duration <= 0)

            Text("\(formatTime(viewModel.currentTime)) / \(formatTime(viewModel.duration))")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 86, alignment: .trailing)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else {
            return "0:00"
        }

        let totalSeconds = Int(seconds.rounded(.down))
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}
