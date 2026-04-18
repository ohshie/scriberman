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
            ZStack(alignment: .leading) {
                ForEach(0 ..< doneCheckmarkCount, id: \.self) { i in
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                        .font(.caption.weight(.semibold))
                        .offset(x: CGFloat(i) * 5, y: CGFloat(-i) * 3)
                }
            }
            .frame(width: 28, height: 14, alignment: .leading)
        case .error:
            Image(systemName: "xmark")
                .foregroundStyle(.red.opacity(0.6))
                .font(.caption.weight(.semibold))
        case .recorded, .converting, .transcribing, .retranscribing:
            Text("Pending")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: Capsule())
                .tint(.orange)
        }
    }

    private var doneCheckmarkCount: Int {
        var count = 1
        if hasTranscript { count += 1 }
        if hasAITransformation { count += 1 }
        return count
    }
}
