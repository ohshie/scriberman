import SwiftUI

struct StatusTagView: View {
    let status: RecordingStatus

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
        case .recorded, .converting, .transcribing, .retranscribing:
            Text("Pending")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color("StatusPendingColor"))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: Capsule())
                .tint(Color("StatusPendingColor"))
        }
    }
}
