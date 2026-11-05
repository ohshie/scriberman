import Foundation
import Observation

/// The app's pairing presenter: holds the request on screen and passes the user's answer to the
/// handler once. The panel follows `current` through `onChange`.
@MainActor
@Observable
final class ExtensionAPIPairingPrompter: ExtensionAPIPairingPresenter {
    private(set) var current: ExtensionAPIPairingRequest?
    /// Called with the request to show, or nil to hide the prompt.
    @ObservationIgnored var onChange: ((ExtensionAPIPairingRequest?) -> Void)?
    @ObservationIgnored private var decide: (@MainActor (ExtensionAPIPairingDecision) -> Void)?

    func present(_ request: ExtensionAPIPairingRequest, decide: @escaping @MainActor (ExtensionAPIPairingDecision) -> Void) {
        current = request
        self.decide = decide
        onChange?(request)
    }

    func withdraw(_ request: ExtensionAPIPairingRequest) {
        guard current?.id == request.id else { return }
        clear()
    }

    func approve() {
        answer(.approve)
    }

    func deny() {
        answer(.deny)
    }

    private func answer(_ decision: ExtensionAPIPairingDecision) {
        guard current != nil, let decide else { return }
        clear()
        decide(decision)
    }

    private func clear() {
        current = nil
        decide = nil
        onChange?(nil)
    }
}

/// What the pairing prompt shows for one request.
struct ExtensionAPIPairingPromptContent: Equatable {
    let claimedNameText: String
    /// The signing identifier the OS verified, or nil when none was recorded.
    let signingIdentifier: String?
    let teamText: String

    init(_ request: ExtensionAPIPairingRequest) {
        claimedNameText = ExtensionAPIStrings.claimedName(request.claimedName)
        signingIdentifier = request.callerIdentity.signingIdentifier
        teamText = request.callerIdentity.teamText
    }
}

extension ExtensionAPICallerIdentity {
    /// The verified team, or the no-team text when the signature has none.
    var teamText: String {
        teamIdentifier ?? ExtensionAPIStrings.noTeam
    }
}
