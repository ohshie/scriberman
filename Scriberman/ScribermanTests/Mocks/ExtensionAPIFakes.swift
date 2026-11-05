import CryptoKit
import Foundation
@testable import Scriberman

/// A caller verifier whose answers the test sets. Records every peer it was asked about.
final class FakeCallerVerifier: ExtensionAPICallerVerifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _pairingIdentity: ExtensionAPICallerIdentity? = ExtensionAPICallerIdentity(designatedRequirement: "identifier \"fake\"")
    private var _acceptsRequests = true
    private var _pairingCalls = 0
    private var _verifyCalls: [ExtensionAPICallerIdentity] = []

    /// What pairing returns; nil refuses the caller.
    var pairingIdentity: ExtensionAPICallerIdentity? {
        get { lock.withLock { _pairingIdentity } }
        set { lock.withLock { _pairingIdentity = newValue } }
    }

    var acceptsRequests: Bool {
        get { lock.withLock { _acceptsRequests } }
        set { lock.withLock { _acceptsRequests = newValue } }
    }

    var pairingCalls: Int { lock.withLock { _pairingCalls } }
    var verifyCalls: [ExtensionAPICallerIdentity] { lock.withLock { _verifyCalls } }

    func identityForPairing(_ peer: ExtensionAPIPeer) async -> ExtensionAPICallerIdentity? {
        lock.withLock {
            _pairingCalls += 1
            return _pairingIdentity
        }
    }

    func verify(_ peer: ExtensionAPIPeer, matches identity: ExtensionAPICallerIdentity) async -> Bool {
        lock.withLock {
            _verifyCalls.append(identity)
            return _acceptsRequests
        }
    }
}

/// A pairing presenter that records what it was shown and lets the test decide.
@MainActor
final class FakePairingPresenter: ExtensionAPIPairingPresenter {
    private(set) var presented: [ExtensionAPIPairingRequest] = []
    private(set) var withdrawn: [ExtensionAPIPairingRequest] = []
    private var decisions: [UUID: @MainActor (ExtensionAPIPairingDecision) -> Void] = [:]
    /// Called after a request is presented, so a test can wait for the prompt.
    var onPresent: (@MainActor (ExtensionAPIPairingRequest) -> Void)?

    func present(_ request: ExtensionAPIPairingRequest, decide: @escaping @MainActor (ExtensionAPIPairingDecision) -> Void) {
        presented.append(request)
        decisions[request.id] = decide
        onPresent?(request)
    }

    func withdraw(_ request: ExtensionAPIPairingRequest) {
        withdrawn.append(request)
    }

    /// Answers the most recent prompt.
    func answer(_ decision: ExtensionAPIPairingDecision) {
        guard let last = presented.last else { return }
        decisions[last.id]?(decision)
    }

    /// Waits until `count` prompts have been presented.
    func waitForPrompts(_ count: Int) async {
        while presented.count < count {
            await Task.yield()
        }
    }
}

/// Stands in for the 2-minute pairing expiry: the wait ends when the test calls `fire()`.
@MainActor
final class ManualPairingExpiry {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waitCount = 0

    func wait() async {
        waitCount += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Ends the current wait, first waiting for the expiry to have started waiting.
    func fire() async {
        while waiters.isEmpty {
            await Task.yield()
        }
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// Signs requests and checks responses the way the extension does, from the spec's description.
struct ExtensionAPITestSigner {
    let clientID: String
    let secret: Data

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    func signature(method: String, target: String, timestamp: String, nonce: String, bodyHash: String) -> String {
        let message = [method, target, timestamp, nonce, bodyHash].joined(separator: "\n")
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: secret))
        return Self.hex(code)
    }

    /// The signing headers for a request, plus Host.
    func headers(
        method: String,
        target: String,
        body: Data = Data(),
        timestamp: Date,
        nonce: String = ExtensionAPITestSigner.randomNonce()
    ) -> [(String, String)] {
        let ts = String(Int(timestamp.timeIntervalSince1970))
        let bodyHash = Self.sha256Hex(body)
        return [
            ("Host", "127.0.0.1:47615"),
            ("X-Scriberman-Client", clientID),
            ("X-Scriberman-Timestamp", ts),
            ("X-Scriberman-Nonce", nonce),
            ("X-Scriberman-Body-SHA256", bodyHash),
            ("X-Scriberman-Signature", signature(method: method, target: target, timestamp: ts, nonce: nonce, bodyHash: bodyHash)),
        ]
    }

    /// Whether a response carries a valid signature for the request nonce.
    func verifies(_ response: HTTPResponse, nonce: String) -> Bool {
        let signatures = response.headers.filter { $0.name.caseInsensitiveCompare("X-Scriberman-Signature") == .orderedSame }
        guard signatures.count == 1 else { return false }
        let message = [nonce, String(response.status), Self.sha256Hex(response.body)].joined(separator: "\n")
        let expected = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: secret))
        return signatures[0].value == Self.hex(expected)
    }

    static func randomNonce() -> String {
        hex((0..<16).map { _ in UInt8.random(in: 0...255) })
    }
}
