import SwiftUI

struct StatusTagView: View {
    enum TintToken: String, Equatable {
        case green
        case orange
        case red

        var color: Color {
            switch self {
            case .green:
                return .green
            case .orange:
                return .orange
            case .red:
                return .red
            }
        }
    }

    struct Style: Equatable {
        let label: String
        let tint: TintToken
    }

    let status: RecordingStatus

    static func style(for status: RecordingStatus) -> Style {
        switch status {
        case .recording:
            return Style(label: "Recording", tint: .orange)
        case .done:
            return Style(label: "Done", tint: .green)
        case .error:
            return Style(label: "Failed", tint: .red)
        case .recorded, .converting, .transcribing, .retranscribing:
            return Style(label: "Pending", tint: .orange)
        }
    }

    var body: some View {
        let style = Self.style(for: status)
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(style.tint.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: Capsule())
            .tint(style.tint.color)
    }

    private var label: String {
        Self.style(for: status).label
    }
}
