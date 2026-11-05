import Foundation
import Observation
import OSLog
import Security

/// A client that paired with the API.
struct ExtensionAPIPairedClient: Codable, Equatable, Sendable, Identifiable {
    let id: String
    /// The name the client gave. Its own claim, not verified.
    let name: String
    let pairedAt: Date
    /// The caller identity recorded at pairing; later requests must match it.
    let callerIdentity: ExtensionAPICallerIdentity
}

/// A client's record and secret, read together for one request.
struct ExtensionAPIClientCredentials: Sendable {
    let client: ExtensionAPIPairedClient
    let secret: Data
}

/// Paired clients in user defaults, each client's secret in the Keychain. Secrets are never logged.
/// Observable so Settings lists a client paired or revoked while it is open.
@MainActor
@Observable
final class ExtensionAPIPairingStore {
    nonisolated static let secretByteCount = 32
    private static let clientsKey = "extensionAPI.pairedClients"
    private static let secretKeyPrefix = "extensionAPI.clientSecret."

    /// Bumped on every save; `clients` reads it so observers see changes to user defaults.
    private var revision = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: any KeychainStore
    @ObservationIgnored private let makeSecret: () -> Data?
    @ObservationIgnored private let logger = Logger(subsystem: "Scriberman", category: "ExtensionAPIPairingStore")

    private struct SigningIdentity: Hashable {
        let identifier: String
        let team: String?

        init?(_ caller: ExtensionAPICallerIdentity) {
            guard let identifier = caller.signingIdentifier, !identifier.isEmpty else { return nil }
            self.identifier = identifier
            team = caller.teamIdentifier
        }
    }

    init(
        defaults: UserDefaults = .standard,
        keychain: any KeychainStore,
        makeSecret: @escaping () -> Data? = ExtensionAPIPairingStore.randomSecret
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.makeSecret = makeSecret
        removeDuplicateClients()
    }

    enum PairError: Error {
        case secretUnavailable
        case keychain(any Error)
    }

    var clients: [ExtensionAPIPairedClient] {
        _ = revision
        guard let data = defaults.data(forKey: Self.clientsKey) else { return [] }
        return (try? JSONDecoder().decode([ExtensionAPIPairedClient].self, from: data)) ?? []
    }

    func isPaired(_ clientID: String) -> Bool {
        clients.contains { $0.id == clientID }
    }

    /// Records a new client with a fresh secret. The client is listed only once its secret is in
    /// the Keychain.
    func pair(name: String, callerIdentity: ExtensionAPICallerIdentity, at date: Date) throws -> ExtensionAPIClientCredentials {
        guard let secret = makeSecret(), secret.count == Self.secretByteCount else {
            throw PairError.secretUnavailable
        }
        let client = ExtensionAPIPairedClient(id: UUID().uuidString, name: name, pairedAt: date, callerIdentity: callerIdentity)
        do {
            try keychain.save(key: Self.secretKey(client.id), value: ExtensionAPISigning.hex(secret))
        } catch {
            logger.error("Extension API pairing could not save the client secret: \(String(describing: error), privacy: .public)")
            throw PairError.keychain(error)
        }
        let existing = clients
        let replaced: [ExtensionAPIPairedClient]
        if let identity = SigningIdentity(callerIdentity) {
            replaced = existing.filter { SigningIdentity($0.callerIdentity) == identity }
        } else {
            replaced = []
        }
        let replacedIDs = Set(replaced.map(\.id))
        save(existing.filter { !replacedIDs.contains($0.id) } + [client])
        for previous in replaced { deleteSecret(previous.id) }
        return ExtensionAPIClientCredentials(client: client, secret: secret)
    }

    /// The client and its secret, or nil when the client is unknown or its secret can't be read.
    /// A listed client whose secret is missing from the Keychain is removed.
    func credentials(for clientID: String) -> ExtensionAPIClientCredentials? {
        guard let client = clients.first(where: { $0.id == clientID }) else { return nil }
        let stored: String?
        do {
            stored = try keychain.readIfPresent(key: Self.secretKey(clientID))
        } catch {
            logger.error("Extension API could not read a client secret from the Keychain: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let stored else {
            logger.error("Extension API client has no secret in the Keychain; removing it")
            save(clients.filter { $0.id != clientID })
            return nil
        }
        guard let secret = ExtensionAPISigning.bytes(fromHex: stored), secret.count == Self.secretByteCount else {
            logger.error("Extension API client secret in the Keychain is malformed")
            return nil
        }
        return ExtensionAPIClientCredentials(client: client, secret: secret)
    }

    /// Removes the client. It is revoked even if its secret can't be deleted from the Keychain,
    /// because a client must be listed to be accepted.
    func revoke(_ clientID: String) {
        save(clients.filter { $0.id != clientID })
        deleteSecret(clientID)
    }

    private func removeDuplicateClients() {
        let existing = clients
        var latest: [SigningIdentity: ExtensionAPIPairedClient] = [:]
        for client in existing {
            guard let identity = SigningIdentity(client.callerIdentity) else { continue }
            if let previous = latest[identity], previous.pairedAt > client.pairedAt { continue }
            latest[identity] = client
        }
        let retained = existing.filter { client in
            guard let identity = SigningIdentity(client.callerIdentity) else { return true }
            return latest[identity]?.id == client.id
        }
        guard retained.count != existing.count else { return }
        save(retained)
        let retainedIDs = Set(retained.map(\.id))
        for client in existing where !retainedIDs.contains(client.id) { deleteSecret(client.id) }
    }

    private func deleteSecret(_ clientID: String) {
        do {
            try keychain.delete(key: Self.secretKey(clientID))
        } catch {
            logger.error("Extension API could not delete a revoked client's secret: \(String(describing: error), privacy: .public)")
        }
    }

    private func save(_ clients: [ExtensionAPIPairedClient]) {
        guard let data = try? JSONEncoder().encode(clients) else { return }
        defaults.set(data, forKey: Self.clientsKey)
        revision += 1
    }

    private static func secretKey(_ clientID: String) -> String {
        secretKeyPrefix + clientID
    }

    nonisolated static func randomSecret() -> Data? {
        var bytes = [UInt8](repeating: 0, count: secretByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }
}

/// One pairing request as the user sees it.
struct ExtensionAPIPairingRequest: Equatable, Sendable, Identifiable {
    let id: UUID
    /// The name the client sent. Shown as the client's own claim.
    let claimedName: String
    /// The identity the caller verifier read from the operating system for this request.
    let callerIdentity: ExtensionAPICallerIdentity
}

enum ExtensionAPIPairingDecision: Equatable, Sendable {
    case approve
    case deny
}

/// Shows a pairing request to the user and reports the answer.
@MainActor
protocol ExtensionAPIPairingPresenter: AnyObject {
    /// Shows the request. `decide` may be called once; calls after the request ended are ignored.
    func present(_ request: ExtensionAPIPairingRequest, decide: @escaping @MainActor (ExtensionAPIPairingDecision) -> Void)
    /// Removes a request that expired, whose client disconnected, or that ended because the API
    /// was turned off.
    func withdraw(_ request: ExtensionAPIPairingRequest)
}
