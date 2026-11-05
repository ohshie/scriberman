import SwiftUI

/// Settings for the local extension API: on/off, port, listener status and paired clients.
struct ExtensionAPISettingsSection: View {
    @Bindable var model: ExtensionAPISettingsViewModel
    @FocusState private var isPortFocused: Bool

    var body: some View {
        Section(ExtensionAPIStrings.sectionTitle) {
            Toggle(ExtensionAPIStrings.enableToggle, isOn: $model.isEnabled)
            Text(ExtensionAPIStrings.enableHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(ExtensionAPIStrings.portLabel, text: $model.portText)
                .focused($isPortFocused)
                .onSubmit { model.commitPort() }
                .onChange(of: isPortFocused) { _, focused in
                    if !focused { model.commitPort() }
                }
            if let portError = model.portError {
                Text(portError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(model.portHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let status = model.status
            Text(status.text)
                .font(.footnote)
                .foregroundStyle(status.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
        }

        Section(ExtensionAPIStrings.pairedClientsTitle) {
            let clients = model.clients
            if clients.isEmpty {
                Text(ExtensionAPIStrings.noClients)
                    .foregroundStyle(.secondary)
            }
            ForEach(clients) { client in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(client.name)
                        Text(client.pairedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let signingIdentifier = client.signingIdentifier {
                            LabeledContent(ExtensionAPIStrings.signingIdentifierLabel) {
                                Text(signingIdentifier).textSelection(.enabled)
                            }
                            .font(.caption)
                            LabeledContent(ExtensionAPIStrings.teamLabel) {
                                Text(client.teamText).textSelection(.enabled)
                            }
                            .font(.caption)
                        }
                        if client.needsPairingAgain {
                            Text(ExtensionAPIStrings.pairAgainNotice)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button(ExtensionAPIStrings.revokeButton, role: .destructive) {
                        model.revoke(client.id)
                    }
                }
            }
        }
    }
}
