import SwiftUI

/// Content of the floating pairing prompt. Styled like the idle session prompt.
struct ExtensionAPIPairingPanelView: View {
    let content: ExtensionAPIPairingPromptContent
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ExtensionAPIStrings.pairingTitle)
                .font(.headline)

            Text(content.claimedNameText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                if let signingIdentifier = content.signingIdentifier {
                    LabeledContent(ExtensionAPIStrings.signingIdentifierLabel) {
                        Text(signingIdentifier).textSelection(.enabled)
                    }
                }
                LabeledContent(ExtensionAPIStrings.teamLabel) {
                    Text(content.teamText).textSelection(.enabled)
                }
            }
            .font(.callout)

            HStack(spacing: 10) {
                Button(ExtensionAPIStrings.approveButton, action: onApprove)
                    .buttonStyle(.bordered)
                Button(ExtensionAPIStrings.denyButton, action: onDeny)
                    .buttonStyle(.bordered)
            }
        }
        .frame(width: 280, alignment: .leading)
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
