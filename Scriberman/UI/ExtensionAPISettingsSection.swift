import SwiftUI

/// Settings for the local extension API: on/off, port and paired clients.
struct ExtensionAPISettingsSection: View {
    @Bindable var model: ExtensionAPISettingsViewModel
    @FocusState private var isPortFocused: Bool

    var body: some View {
        Section {
            Toggle(ExtensionAPIStrings.enableToggle, isOn: $model.isEnabled)
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
            }
            if let listenerError = model.listenerError {
                Text(listenerError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text(ExtensionAPIStrings.sectionTitle)
        } footer: {
            Text(ExtensionAPIStrings.enableHelp)
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
                            DisclosureGroup(ExtensionAPIStrings.signingDetails) {
                                LabeledContent(ExtensionAPIStrings.signingIdentifierLabel) {
                                    Text(signingIdentifier).textSelection(.enabled)
                                }
                                LabeledContent(ExtensionAPIStrings.teamLabel) {
                                    Text(client.teamText).textSelection(.enabled)
                                }
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
