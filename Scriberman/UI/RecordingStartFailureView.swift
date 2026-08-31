import SwiftUI

/// Content of the floating panel shown when a recording was stopped because it never started
/// writing audio. Nothing was captured, so there is nothing to save or resume — the panel exists
/// to make sure the user does not believe the meeting is being recorded.
struct RecordingStartFailureView: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recording failed.")
                .font(.headline)

            HStack(spacing: 10) {
                Button("Open Scriberman") {
                    onOpen()
                }
                .buttonStyle(.borderedProminent)

                Button("Dismiss") {
                    onDismiss()
                }
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
