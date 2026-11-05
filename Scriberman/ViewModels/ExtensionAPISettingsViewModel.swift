import Foundation
import Network
import Observation

/// The extension API section of Settings: the enable toggle, the port field, the listener's
/// status and the paired clients.
@MainActor
@Observable
final class ExtensionAPISettingsViewModel {
    struct Status: Equatable {
        let text: String
        let isFailure: Bool
    }

    struct ClientRow: Equatable, Identifiable {
        let id: String
        /// The client's own claim.
        let name: String
        let pairedText: String
        /// Verified at pairing; nil for a client paired before identities were recorded.
        let signingIdentifier: String?
        let teamText: String
        /// No requirement was recorded at pairing, so every request is refused until it pairs again.
        let needsPairingAgain: Bool
    }

    var portText: String
    private(set) var portError: String?

    @ObservationIgnored private let settings: ExtensionAPISettings
    @ObservationIgnored private let pairingStore: ExtensionAPIPairingStore
    @ObservationIgnored private let state: @MainActor () -> ExtensionAPIService.State
    @ObservationIgnored private let dateText: (Date) -> String

    init(
        settings: ExtensionAPISettings,
        pairingStore: ExtensionAPIPairingStore,
        state: @escaping @MainActor () -> ExtensionAPIService.State,
        dateText: @escaping (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }
    ) {
        self.settings = settings
        self.pairingStore = pairingStore
        self.state = state
        self.dateText = dateText
        portText = String(settings.port)
    }

    var isEnabled: Bool {
        get { settings.isEnabled }
        set { settings.isEnabled = newValue }
    }

    var portHelp: String {
        ExtensionAPIStrings.portHelp(min: ExtensionAPISettings.validPorts.lowerBound, max: ExtensionAPISettings.validPorts.upperBound)
    }

    /// Saves the typed port, or keeps the current one and shows why.
    func commitPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        guard let port = Int(trimmed), (try? settings.setPort(port)) != nil else {
            portError = ExtensionAPIStrings.portInvalid(
                min: ExtensionAPISettings.validPorts.lowerBound,
                max: ExtensionAPISettings.validPorts.upperBound
            )
            return
        }
        portError = nil
        portText = String(port)
    }

    var status: Status {
        switch state() {
        case .listening(let port):
            return Status(text: ExtensionAPIStrings.listening(port: port), isFailure: false)
        case .failed(let failure):
            if failure.error == .posix(.EADDRINUSE) {
                return Status(text: ExtensionAPIStrings.portInUse(port: failure.port), isFailure: true)
            }
            let detail = failure.error?.localizedDescription ?? ""
            return Status(text: ExtensionAPIStrings.bindFailed(port: failure.port, detail: detail), isFailure: true)
        case .stopped:
            return Status(text: settings.isEnabled ? ExtensionAPIStrings.starting : ExtensionAPIStrings.off, isFailure: false)
        }
    }

    var clients: [ClientRow] {
        pairingStore.clients.map { client in
            ClientRow(
                id: client.id,
                name: client.name,
                pairedText: ExtensionAPIStrings.pairedOn(dateText(client.pairedAt)),
                signingIdentifier: client.callerIdentity.signingIdentifier,
                teamText: client.callerIdentity.teamText,
                needsPairingAgain: client.callerIdentity.designatedRequirement == nil
            )
        }
    }

    /// Removes the client and its secret. A request it has in flight is refused at its next check.
    func revoke(_ clientID: String) {
        pairingStore.revoke(clientID)
    }
}
