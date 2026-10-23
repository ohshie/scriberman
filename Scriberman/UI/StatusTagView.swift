import SwiftUI

struct StatusTagView: View {
    let status: RecordingStatus

    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    var body: some View {
        switch status {
        case .recording:
            EmptyView()
        case .done:
            // Only exceptional states are marked. `.done` is the resting state and most of the
            // list, so it carries nothing — not even a checkmark, which would only repeat the
            // status. Whether a session has a transcript or an AI transformation is no longer
            // shown here; opening it shows both.
            EmptyView()
        case .error:
            Image(systemName: "xmark")
                .foregroundStyle(Color("StatusErrorColor"))
                .font(.caption.weight(.semibold))
                .frame(width: 8, height: 8, alignment: .center)
                .accessibilityLabel("Recording failed")
                .help("Recording failed")
        case .recorded, .converting, .transcribing, .retranscribing:
            Text("Pending")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color("StatusPendingColor"))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                // Plain fill, no Liquid Glass: the pill is list content, and glass is for controls
                // and navigation. Increase Contrast adds an outline.
                .background(Capsule().fill(Color("StatusPendingColor").opacity(0.18)))
                .overlay {
                    if contrast == .increased {
                        Capsule().strokeBorder(Color("StatusPendingColor"))
                    }
                }
        }
    }
}
