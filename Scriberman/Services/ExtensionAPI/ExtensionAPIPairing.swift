import Foundation
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
@MainActor
final class ExtensionAPIPairingStore {
    nonisolated static let secretByteCount = 32
    private static let clientsKey = "extensionAPI.pairedClients"
    private static let secretKeyPrefix = "extensionAPI.clientSecret."

    private let defaults: UserDefaults
    private let keychain: any KeychainStore
    private let makeSecret: () -> Data?
    private let logger = Logger(subsystem: "Scriberman", category: "ExtensionAPIPairingStore")

    init(
        defaults: UserDefaults = .standard,
        keychain: any KeychainStore,
        makeSecret: @escaping () -> Data? = ExtensionAPIPairingStore.randomSecret
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.makeSecret = makeSecret
    }

    enum PairError: Error {
        case secretUnavailable
        case keychain(any Error)
    }

    var clients: [ExtensionAPIPairedClient] {
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
        save(clients + [client])
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
        do {
            try keychain.delete(key: Self.secretKey(clientID))
        } catch {
            logger.error("Extension API could not delete a revoked client's secret: \(String(describing: error), privacy: .public)")
        }
    }

    private func save(_ clients: [ExtensionAPIPairedClient]) {
        guard let data = try? JSONEncoder().encode(clients) else { return }
        defaults.set(data, forKey: Self.clientsKey)
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
}

enum ExtensionAPIPairingDecision: Equatable, Sendable {
    case approve
    case deny
}

/// Shows a pairing request to the user and reports the answer. Its UI is ticket 13.
@MainActor
protocol ExtensionAPIPairingPresenter: AnyObject {
    /// Shows the request. `decide` may be called once; calls after the request ended are ignored.
    func present(_ request: ExtensionAPIPairingRequest, decide: @escaping @MainActor (ExtensionAPIPairingDecision) -> Void)
    /// Removes a request that expired, whose client disconnected, or that ended because the API
    /// was turned off.
    func withdraw(_ request: ExtensionAPIPairingRequest)
}
