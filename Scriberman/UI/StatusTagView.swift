import SwiftUI

struct StatusTagView: View {
    let status: RecordingStatus
    let hasTranscript: Bool
    let hasAITransformation: Bool

    @ViewBuilder
    var body: some View {
        switch status {
        case .recording:
            EmptyView()
        case .done:
            ZStack(alignment: .trailing) {
                ForEach(0 ..< doneCheckmarkCount, id: \.self) { i in
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color("StatusDoneMarkColor"))
                        .font(.caption.weight(.semibold))
                        .offset(x: CGFloat(-i) * 4)
                }
            }
            .frame(width: 8, height: 8, alignment: .center)
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

    private var doneCheckmarkCount: Int {
        var count = 1
        if hasTranscript { count += 1 }
        if hasAITransformation { count += 1 }
        return count
    }
}
