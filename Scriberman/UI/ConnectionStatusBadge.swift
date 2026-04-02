import SwiftUI

struct ConnectionStatusBadge: View {
    let status: ConnectionStatus

    var body: some View {
        switch status {
        case .unknown:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
