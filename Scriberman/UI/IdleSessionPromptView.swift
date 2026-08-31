import SwiftUI

/// Content of the floating "Still in progress. Stop?" prompt shown when a mic + app
/// recording has been idle for the configured threshold. Recording continues while this is
/// on screen; the panel persists until the user acts or activity resumes.
struct IdleSessionPromptView: View {
    let onStop: () -> Void
    let onSnooze: (TimeInterval) -> Void

    private static let snoozeOptions: [Int] = [5, 10, 15]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Still in progress. Stop?")
                .font(.headline)

            HStack(spacing: 10) {
                Button("Stop & Save") {
                    onStop()
                }
                .buttonStyle(.borderedProminent)

                Menu {
                    ForEach(Self.snoozeOptions, id: \.self) { minutes in
                        Button("\(minutes) minutes") {
                            onSnooze(TimeInterval(minutes) * 60)
                        }
                    }
                } label: {
                    Text("Snooze \(Self.snoozeOptions[0])")
                } primaryAction: {
                    onSnooze(TimeInterval(Self.snoozeOptions[0]) * 60)
                }
                .menuStyle(.button)
                .fixedSize()
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.secondary.opacity(0.2), lineWidth: 1)
        }
    }
}
