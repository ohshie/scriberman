import SwiftUI

struct AudioPlayerBar: View {
    let viewModel: AudioPlayerViewModel
    let sessionHasAudio: Bool
    let mixdownURL: String?
    let onResumeScroll: (() -> Void)?

    @State private var previousMixdownURL: String?

    init(
        viewModel: AudioPlayerViewModel,
        sessionHasAudio: Bool,
        mixdownURL: String?,
        onResumeScroll: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.sessionHasAudio = sessionHasAudio
        self.mixdownURL = mixdownURL
        self.onResumeScroll = onResumeScroll
    }

    var body: some View {
        Group {
            // Nothing until there is something to play. The bar used to float a spinner and
            // "Getting recording ready…" over the recording, which is a progress report on a file
            // nobody asked for yet — the recording itself is what the window is showing.
            if sessionHasAudio, viewModel.isReady {
                HStack(spacing: 12) {
                    readyContent
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .onAppear {
            previousMixdownURL = mixdownURL
            loadMixdownIfAvailable()
        }
        .onChange(of: mixdownURL) {
            previousMixdownURL = mixdownURL
            loadMixdownIfAvailable()
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
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

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
            .accessibilityLabel("Playback position")
            .accessibilityValue(TimeFormatter.displayFormat(seconds: Float(viewModel.currentTime)))

            Text("\(TimeFormatter.displayFormat(seconds: Float(viewModel.currentTime))) / \(TimeFormatter.displayFormat(seconds: Float(viewModel.duration)))")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 86, alignment: .trailing)

            if let onResumeScroll {
                Button(action: onResumeScroll) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Resume Transcript Auto-Scroll")
                .accessibilityLabel("Resume auto-scroll")
            }
        }
    }

    private func loadMixdownIfAvailable() {
        guard let mixdownURL, mixdownURL.isEmpty == false else {
            return
        }

        let url = URL(fileURLWithPath: mixdownURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        viewModel.load(url: url)
    }
}
