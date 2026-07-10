import SwiftUI

/// Content of the floating dictation HUD (design D5). Observes
/// `DictationService` directly and self-dismisses via `onDismiss` after
/// outcomes are shown.
struct DictationHUDView: View {
    let dictation: DictationService
    var isAccessibilityGranted: () -> Bool = { TextInjector().isAccessibilityGranted }
    var onEnableAccessibility: () -> Void
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    private struct Phase: Equatable {
        let state: DictationState
        let outcome: DictationOutcome?
    }

    private var phase: Phase {
        Phase(state: dictation.state, outcome: dictation.lastOutcome)
    }

    var body: some View {
        content
            .font(.callout)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: phase) {
                await autoDismissIfNeeded()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch dictation.state {
        case .listening:
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                LevelBars(level: dictation.inputLevel)
                Text("Listening…")
                    .foregroundStyle(.secondary)
            }
        case .transcribing, .inserting:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .foregroundStyle(.secondary)
            }
        case .prewarming:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing…")
                    .foregroundStyle(.secondary)
            }
        case .idle:
            outcomeContent
        }
    }

    @ViewBuilder
    private var outcomeContent: some View {
        switch dictation.lastOutcome {
        case .inserted, .typedOut:
            Label("Inserted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .copiedToClipboard:
            HStack(spacing: 10) {
                Label("Copied — press ⌘V", systemImage: "doc.on.clipboard")
                if !isAccessibilityGranted() {
                    Button("Enable text insertion") {
                        onEnableAccessibility()
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        case .failed(.noModel):
            HStack(spacing: 10) {
                Label("Speech model not installed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Button("Open Settings") {
                    onOpenSettings()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .failed(.emptyTranscript):
            Label("Nothing heard", systemImage: "mic.slash")
                .foregroundStyle(.secondary)
        case .failed(.captureFailed):
            Label("Microphone unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .failed(.insertionFailed):
            Label("Couldn't insert here", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case nil:
            Image(systemName: "mic.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var isActionableOutcome: Bool {
        switch dictation.lastOutcome {
        case .copiedToClipboard, .failed(.noModel):
            return true
        default:
            return false
        }
    }

    private func autoDismissIfNeeded() async {
        guard dictation.state == .idle else { return }
        let delay: Duration = isActionableOutcome ? .seconds(5) : .seconds(1.5)
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        onDismiss()
    }
}

private struct LevelBars: View {
    let level: Float

    private static let barCount = 5

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(.tint)
                    .frame(width: 3, height: barHeight(for: index))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.1), value: level)
    }

    private func barHeight(for index: Int) -> CGFloat {
        // RMS of speech typically peaks well under 0.5; scale to full range
        // and stagger the bars so the meter reads as a wave.
        let normalized = min(CGFloat(level) * 4, 1)
        let stagger: [CGFloat] = [0.5, 0.8, 1.0, 0.8, 0.5]
        return max(3, 18 * normalized * stagger[index])
    }
}
