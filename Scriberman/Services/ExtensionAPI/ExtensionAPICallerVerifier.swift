import Foundation
import Network

/// What the operating system reports about the other end of a connection. Never filled from
/// request headers.
struct ExtensionAPIPeer: Sendable, Equatable {
    /// The connection's remote endpoint, as `NWConnection.endpoint` reports it.
    let endpoint: NWEndpoint?
}

/// The caller's code-signing identity, recorded at pairing and kept with the client.
struct ExtensionAPICallerIdentity: Codable, Equatable, Sendable {
    /// The caller's designated requirement, as text. Nil when the verifier can't tell callers
    /// apart (always-allow).
    var designatedRequirement: String?
}

/// Decides whether the process at the other end of a connection may use the API.
protocol ExtensionAPICallerVerifier: Sendable {
    /// At pairing: the identity to store with the new client, or nil to refuse the caller.
    func identityForPairing(_ peer: ExtensionAPIPeer) async -> ExtensionAPICallerIdentity?
    /// On a signed request: whether the caller still has the identity recorded at pairing.
    func verify(_ peer: ExtensionAPIPeer, matches identity: ExtensionAPICallerIdentity) async -> Bool
}

/// Accepts every caller. Used until the real verifier (ticket 14) replaces it.
struct AlwaysAllowCallerVerifier: ExtensionAPICallerVerifier {
    func identityForPairing(_ peer: ExtensionAPIPeer) async -> ExtensionAPICallerIdentity? {
        ExtensionAPICallerIdentity(designatedRequirement: nil)
    }

    func verify(_ peer: ExtensionAPIPeer, matches identity: ExtensionAPICallerIdentity) async -> Bool {
        true
    }
}
