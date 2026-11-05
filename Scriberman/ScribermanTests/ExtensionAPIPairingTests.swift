import Foundation
import Testing
@testable import Scriberman

/// Shared set-up for handler tests that pair and sign: in-memory defaults, a mock Keychain, a fake
/// caller verifier, a fake pairing presenter, a fixed clock and a manual pairing expiry.
@MainActor
final class ExtensionAPIFixture {
    let defaults = UserDefaults(suiteName: "ExtensionAPIFixture-\(UUID().uuidString)")!
    let keychain = MockKeychainStore()
    let verifier = FakeCallerVerifier()
    let presenter = FakePairingPresenter()
    let expiry = ManualPairingExpiry()
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var prompts: [AIPrompt] = []
    /// When set, the prompts route waits on this before it answers, to stand for a suspension.
    var promptsGate: (@MainActor () async -> Void)?
    var peer = ExtensionAPIPeer(endpoint: nil)

    lazy var store = ExtensionAPIPairingStore(defaults: defaults, keychain: keychain)
    lazy var handler: ExtensionAPIHandler = {
        let handler = ExtensionAPIHandler(
            port: { 47615 },
            pairingStore: store,
            callerVerifier: verifier,
            now: { [unowned self] in now },
            waitForPairingExpiry: { [expiry] in await expiry.wait() },
            loadPrompts: { [unowned self] in
                await promptsGate?()
                return prompts
            }
        )
        handler.pairingPresenter = presenter
        return handler
    }()

    struct Pairing: Decodable {
        let clientId: String
        let secret: String
    }

    func pairHead(contentLength: Int = 0) -> HTTPRequestHead {
        HTTPRequestHead(
            method: "POST",
            target: "/v1/pair",
            headers: [.init(name: "Host", value: "127.0.0.1:47615")],
            contentLength: contentLength
        )
    }

    func pairBody(_ name: String) -> Data {
        try! JSONEncoder().encode(["name": name])
    }

    /// Starts a pairing request and returns the task carrying its response.
    func startPairing(name: String = "Tinycast") -> Task<HTTPResponse, Never> {
        let body = pairBody(name)
        let head = pairHead(contentLength: body.count)
        return Task { @MainActor in
            await handler.handle(head, body: body, peer: peer)
        }
    }

    /// Pairs a client end to end with approval and returns a signer for it.
    func pair(name: String = "Tinycast") async throws -> ExtensionAPITestSigner {
        let before = presenter.presented.count
        let task = startPairing(name: name)
        await presenter.waitForPrompts(before + 1)
        presenter.answer(.approve)
        let response = await task.value
        try #require(response.status == 200)
        let pairing = try JSONDecoder().decode(Pairing.self, from: response.body)
        let secret = try #require(Data(hex: pairing.secret))
        return ExtensionAPITestSigner(clientID: pairing.clientId, secret: secret)
    }

    func head(_ method: String, _ target: String, headers: [(String, String)], contentLength: Int = 0) -> HTTPRequestHead {
        HTTPRequestHead(
            method: method,
            target: target,
            headers: headers.map { .init(name: $0.0, value: $0.1) },
            contentLength: contentLength
        )
    }

    /// Runs a request through `admit` and, if admitted, `handle`.
    func send(_ head: HTTPRequestHead, body: Data = Data()) async -> HTTPResponse {
        switch await handler.admit(head, peer: peer) {
        case .refused(let response):
            return response
        case .admitted:
            return await handler.handle(head, body: body, peer: peer)
        }
    }

    /// A signed request from `signer`, sent through `admit` and `handle`.
    func sendSigned(
        _ signer: ExtensionAPITestSigner,
        _ method: String = "GET",
        _ target: String = "/v1/prompts",
        body: Data = Data(),
        nonce: String = ExtensionAPITestSigner.randomNonce()
    ) async -> HTTPResponse {
        let headers = signer.headers(method: method, target: target, body: body, timestamp: now, nonce: nonce)
        return await send(head(method, target, headers: headers, contentLength: body.count), body: body)
    }
}

struct ExtensionAPIErrorBody: Decodable, Equatable {
    let code: String
    let message: String
}

func errorCode(_ response: HTTPResponse) -> String? {
    (try? JSONDecoder().decode(ExtensionAPIErrorBody.self, from: response.body))?.code
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

@MainActor
struct ExtensionAPIPairingTests {
    // MARK: - Approve

    @Test("An approved pairing returns a client id and a 32-byte secret, and the client is listed")
    func approve() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair(name: "Tinycast")

        #expect(signer.secret.count == 32)
        let clients = fixture.store.clients
        #expect(clients.map(\.id) == [signer.clientID])
        #expect(clients.first?.name == "Tinycast")
        #expect(clients.first?.pairedAt == fixture.now)
    }

    @Test("The secret is kept in the Keychain, not in user defaults")
    func secretInKeychain() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let hex = ExtensionAPITestSigner.hex(signer.secret)

        #expect(fixture.keychain.storage.values.contains(hex))
        let defaultsText = fixture.defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        #expect(!defaultsText.contains(hex))
    }

    @Test("Two pairings get different client ids and secrets")
    func distinctSecrets() async throws {
        let fixture = ExtensionAPIFixture()
        let first = try await fixture.pair()
        let second = try await fixture.pair()
        #expect(first.clientID != second.clientID)
        #expect(first.secret != second.secret)
    }

    @Test("The caller identity from the verifier is stored with the client")
    func identityStored() async throws {
        let fixture = ExtensionAPIFixture()
        let identity = ExtensionAPICallerIdentity(designatedRequirement: "anchor apple generic and identifier \"x\"")
        fixture.verifier.pairingIdentity = identity
        let signer = try await fixture.pair()
        #expect(fixture.store.clients.first { $0.id == signer.clientID }?.callerIdentity == identity)
    }

    @Test("Pairing survives a new store over the same defaults and Keychain")
    func persisted() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let reopened = ExtensionAPIPairingStore(defaults: fixture.defaults, keychain: fixture.keychain)
        #expect(reopened.clients.map(\.id) == [signer.clientID])
    }

    // MARK: - Deny, expire, disconnect, stop

    @Test("A denied pairing answers pairing_denied and lists no client")
    func deny() async throws {
        let fixture = ExtensionAPIFixture()
        let task = fixture.startPairing()
        await fixture.presenter.waitForPrompts(1)
        fixture.presenter.answer(.deny)
        let response = await task.value

        #expect(response.status == 403)
        #expect(errorCode(response) == "pairing_denied")
        #expect(fixture.store.clients.isEmpty)
        #expect(fixture.keychain.storage.isEmpty)
    }

    @Test("An unanswered pairing expires with pairing_expired and the prompt is withdrawn")
    func expire() async throws {
        let fixture = ExtensionAPIFixture()
        let task = fixture.startPairing()
        await fixture.presenter.waitForPrompts(1)
        await fixture.expiry.fire()
        let response = await task.value

        #expect(errorCode(response) == "pairing_expired")
        #expect(fixture.presenter.withdrawn == fixture.presenter.presented)
        #expect(fixture.store.clients.isEmpty)
    }

    @Test("Approving a prompt after it expired pairs nothing")
    func approveAfterExpiry() async throws {
        let fixture = ExtensionAPIFixture()
        let task = fixture.startPairing()
        await fixture.presenter.waitForPrompts(1)
        await fixture.expiry.fire()
        _ = await task.value
        fixture.presenter.answer(.approve)

        #expect(fixture.store.clients.isEmpty)
        #expect(fixture.keychain.storage.isEmpty)
    }

    @Test("A client that disconnects withdraws its prompt, and approving it later pairs nothing")
    func disconnect() async throws {
        let fixture = ExtensionAPIFixture()
        let task = fixture.startPairing()
        await fixture.presenter.waitForPrompts(1)
        task.cancel()
        _ = await task.value

        #expect(fixture.presenter.withdrawn == fixture.presenter.presented)
        fixture.presenter.answer(.approve)
        #expect(fixture.store.clients.isEmpty)
    }

    @Test("Turning the API off withdraws a pending prompt and ends the request")
    func apiTurnedOff() async throws {
        let fixture = ExtensionAPIFixture()
        let task = fixture.startPairing()
        await fixture.presenter.waitForPrompts(1)
        await fixture.handler.apiDidStop()
        let response = await task.value

        #expect(response.status != 200)
        #expect(fixture.presenter.withdrawn == fixture.presenter.presented)
        fixture.presenter.answer(.approve)
        #expect(fixture.store.clients.isEmpty)
    }

    // MARK: - Busy

    @Test("A second pairing request while one is pending gets pairing_busy at once and shows no prompt")
    func busy() async throws {
        let fixture = ExtensionAPIFixture()
        let first = fixture.startPairing()
        await fixture.presenter.waitForPrompts(1)

        let second = await fixture.startPairing(name: "Other").value
        #expect(second.status == 409)
        #expect(errorCode(second) == "pairing_busy")
        #expect(fixture.presenter.presented.count == 1)

        fixture.presenter.answer(.deny)
        _ = await first.value
    }

    @Test("After a pairing ends, a new one can be prompted")
    func freeAfterEnd() async throws {
        let fixture = ExtensionAPIFixture()
        let first = fixture.startPairing()
        await fixture.presenter.waitForPrompts(1)
        fixture.presenter.answer(.deny)
        _ = await first.value

        _ = try await fixture.pair()
        #expect(fixture.presenter.presented.count == 2)
    }

    // MARK: - Claimed name

    @Test("The client's name reaches the presenter as given")
    func claimedName() async throws {
        let fixture = ExtensionAPIFixture()
        _ = try await fixture.pair(name: "Scriberman (official)")
        #expect(fixture.presenter.presented.map(\.claimedName) == ["Scriberman (official)"])
    }

    @Test("A client claiming an existing client's name gets its own id and secret, and the first client keeps working")
    func spoofedName() async throws {
        let fixture = ExtensionAPIFixture()
        let original = try await fixture.pair(name: "Tinycast")
        let impostor = try await fixture.pair(name: "Tinycast")

        #expect(impostor.clientID != original.clientID)
        #expect(impostor.secret != original.secret)
        #expect(fixture.store.clients.count == 2)
        let response = await fixture.sendSigned(original)
        #expect(response.status == 200)
    }

    @Test("A pairing body without a name is invalid_request and shows no prompt", arguments: ["", "{}", #"{"name":5}"#, "not json"])
    func invalidBody(body: String) async throws {
        let fixture = ExtensionAPIFixture()
        let data = Data(body.utf8)
        let response = await fixture.handler.handle(fixture.pairHead(contentLength: data.count), body: data, peer: fixture.peer)
        #expect(response.status == 400)
        #expect(errorCode(response) == "invalid_request")
        #expect(fixture.presenter.presented.isEmpty)
    }

    @Test("Without a presenter, pairing is denied")
    func noPresenter() async throws {
        let fixture = ExtensionAPIFixture()
        fixture.handler.pairingPresenter = nil
        let response = await fixture.startPairing().value
        #expect(errorCode(response) == "pairing_denied")
        #expect(fixture.store.clients.isEmpty)
    }

    @Test("A Keychain that cannot save denies the pairing and lists no client")
    func keychainSaveFails() async throws {
        let fixture = ExtensionAPIFixture()
        fixture.keychain.failsSaves = true
        let task = fixture.startPairing()
        await fixture.presenter.waitForPrompts(1)
        fixture.presenter.answer(.approve)
        let response = await task.value

        #expect(response.status != 200)
        #expect(fixture.store.clients.isEmpty)
    }

    // MARK: - Caller verifier

    @Test("Pairing asks the caller verifier in admit and again before the prompt")
    func verifierBeforePrompt() async throws {
        let fixture = ExtensionAPIFixture()
        let admission = await fixture.handler.admit(fixture.pairHead(), peer: fixture.peer)
        #expect(admission == .admitted(bodyLimit: ExtensionAPIHandler.defaultBodyLimit))
        #expect(fixture.verifier.pairingCalls == 1)

        _ = try await fixture.pair()
        #expect(fixture.verifier.pairingCalls == 2)
    }

    @Test("A caller the verifier refuses gets forbidden_caller from admit")
    func verifierRefusesInAdmit() async throws {
        let fixture = ExtensionAPIFixture()
        fixture.verifier.pairingIdentity = nil
        let admission = await fixture.handler.admit(fixture.pairHead(), peer: fixture.peer)
        guard case .refused(let response) = admission else {
            Issue.record("admitted")
            return
        }
        #expect(response.status == 403)
        #expect(errorCode(response) == "forbidden_caller")
    }

    @Test("A caller the verifier refuses gets forbidden_caller and no prompt is shown")
    func verifierRefusesBeforePrompt() async throws {
        let fixture = ExtensionAPIFixture()
        fixture.verifier.pairingIdentity = nil
        let response = await fixture.startPairing().value
        #expect(response.status == 403)
        #expect(errorCode(response) == "forbidden_caller")
        #expect(fixture.presenter.presented.isEmpty)
    }
}
