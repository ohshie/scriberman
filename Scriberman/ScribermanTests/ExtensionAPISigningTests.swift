import Foundation
import Testing
@testable import Scriberman

@MainActor
struct ExtensionAPISigningTests {
    private struct PromptList: Decodable, Equatable {
        struct Prompt: Decodable, Equatable {
            let id: String
            let name: String
        }

        let prompts: [Prompt]
    }

    /// Replaces one header's value in a signed header list.
    private func replacing(_ name: String, with value: String, in headers: [(String, String)]) -> [(String, String)] {
        headers.map { $0.0 == name ? ($0.0, value) : $0 }
    }

    // MARK: - Prompts route

    @Test("A signed GET /v1/prompts returns the saved prompts' ids and names")
    func prompts() async throws {
        let fixture = ExtensionAPIFixture()
        let first = AIPrompt(name: "Summary", content: "Summarise")
        let second = AIPrompt(name: "Actions", content: "List actions")
        fixture.prompts = [first, second]
        let signer = try await fixture.pair()

        let response = await fixture.sendSigned(signer)
        #expect(response.status == 200)
        let list = try JSONDecoder().decode(PromptList.self, from: response.body)
        #expect(list == PromptList(prompts: [
            .init(id: first.id.uuidString, name: "Summary"),
            .init(id: second.id.uuidString, name: "Actions"),
        ]))
    }

    @Test("The prompts route does not return prompt content")
    func promptsWithoutContent() async throws {
        let fixture = ExtensionAPIFixture()
        fixture.prompts = [AIPrompt(name: "Summary", content: "SECRET-CONTENT-123")]
        let signer = try await fixture.pair()
        let response = await fixture.sendSigned(signer)
        #expect(!String(decoding: response.body, as: UTF8.self).contains("SECRET-CONTENT-123"))
    }

    // MARK: - Response signature

    @Test("A successful response is signed over the request nonce, status and body hash")
    func successSigned() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let nonce = ExtensionAPITestSigner.randomNonce()
        let response = await fixture.sendSigned(signer, nonce: nonce)
        #expect(response.status == 200)
        #expect(signer.verifies(response, nonce: nonce))
    }

    @Test("A response signature does not verify with another nonce")
    func signatureBoundToNonce() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let response = await fixture.sendSigned(signer)
        #expect(!signer.verifies(response, nonce: ExtensionAPITestSigner.randomNonce()))
    }

    @Test("Error responses to a known client are signed", arguments: ["stale", "replayed", "badSignature", "bodyHash", "callerRefused", "tooLarge"])
    func errorsSigned(kind: String) async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let nonce = ExtensionAPITestSigner.randomNonce()
        var target = "/v1/prompts"
        var method = "GET"
        var body = Data()
        var contentLength = 0
        var timestamp = fixture.now
        switch kind {
        case "stale": timestamp = fixture.now.addingTimeInterval(-61)
        case "replayed": _ = await fixture.sendSigned(signer, nonce: nonce)
        case "callerRefused": fixture.verifier.acceptsRequests = false
        case "tooLarge": (method, target, contentLength) = ("POST", "/v1/recordings", ExtensionAPIHandler.defaultBodyLimit + 1)
        default: break
        }
        var headers = signer.headers(method: method, target: target, body: body, timestamp: timestamp, nonce: nonce)
        if kind == "badSignature" {
            headers = replacing("X-Scriberman-Signature", with: String(repeating: "0", count: 64), in: headers)
        }
        if kind == "bodyHash" {
            body = Data("other".utf8)
            contentLength = body.count
        }
        let response = await fixture.send(fixture.head(method, target, headers: headers, contentLength: contentLength), body: body)

        #expect(response.status >= 400)
        #expect(signer.verifies(response, nonce: nonce))
    }

    // MARK: - Request checks

    @Test("A wrong signature is bad_signature")
    func badSignature() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let other = ExtensionAPITestSigner(clientID: signer.clientID, secret: Data(repeating: 7, count: 32))
        let response = await fixture.sendSigned(other)
        #expect(response.status == 401)
        #expect(errorCode(response) == "bad_signature")
    }

    @Test("A signature over another path is bad_signature")
    func signatureOverOtherPath() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let headers = signer.headers(method: "GET", target: "/v1/prompts?x=1", timestamp: fixture.now)
        let response = await fixture.send(fixture.head("GET", "/v1/prompts", headers: headers))
        #expect(errorCode(response) == "bad_signature")
    }

    @Test("A timestamp more than 60 seconds off is stale_request", arguments: [-61.0, 61.0, -3600.0])
    func stale(offset: TimeInterval) async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let headers = signer.headers(method: "GET", target: "/v1/prompts", timestamp: fixture.now.addingTimeInterval(offset))
        let response = await fixture.send(fixture.head("GET", "/v1/prompts", headers: headers))
        #expect(response.status == 401)
        #expect(errorCode(response) == "stale_request")
    }

    @Test("A timestamp up to 60 seconds off is accepted", arguments: [-60.0, 60.0])
    func withinWindow(offset: TimeInterval) async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let headers = signer.headers(method: "GET", target: "/v1/prompts", timestamp: fixture.now.addingTimeInterval(offset))
        let response = await fixture.send(fixture.head("GET", "/v1/prompts", headers: headers))
        #expect(response.status == 200)
    }

    @Test("A nonce used again within 120 seconds is replayed_request")
    func replayed() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let nonce = ExtensionAPITestSigner.randomNonce()
        #expect(await fixture.sendSigned(signer, nonce: nonce).status == 200)
        fixture.now = fixture.now.addingTimeInterval(119)
        let response = await fixture.sendSigned(signer, nonce: nonce)
        #expect(response.status == 401)
        #expect(errorCode(response) == "replayed_request")
    }

    @Test("A replay of the exact same request is replayed_request")
    func exactReplay() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let headers = signer.headers(method: "GET", target: "/v1/prompts", timestamp: fixture.now)
        let head = fixture.head("GET", "/v1/prompts", headers: headers)
        #expect(await fixture.send(head).status == 200)
        #expect(errorCode(await fixture.send(head)) == "replayed_request")
    }

    @Test("A badly signed request does not use up its nonce")
    func forgeryKeepsNonce() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let nonce = ExtensionAPITestSigner.randomNonce()
        let forger = ExtensionAPITestSigner(clientID: signer.clientID, secret: Data(repeating: 1, count: 32))
        #expect(errorCode(await fixture.sendSigned(forger, nonce: nonce)) == "bad_signature")
        #expect(await fixture.sendSigned(signer, nonce: nonce).status == 200)
    }

    @Test("A body that doesn't match its declared hash is bad_signature")
    func bodyHashMismatch() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let signedBody = Data(#"{"a":1}"#.utf8)
        let sentBody = Data(#"{"a":2}"#.utf8)
        let headers = signer.headers(method: "GET", target: "/v1/prompts", body: signedBody, timestamp: fixture.now)
        let response = await fixture.send(fixture.head("GET", "/v1/prompts", headers: headers, contentLength: sentBody.count), body: sentBody)
        #expect(response.status == 401)
        #expect(errorCode(response) == "bad_signature")
    }

    @Test("An unknown client id is unauthorized")
    func unknownClient() async throws {
        let fixture = ExtensionAPIFixture()
        _ = try await fixture.pair()
        let stranger = ExtensionAPITestSigner(clientID: UUID().uuidString, secret: Data(repeating: 3, count: 32))
        let response = await fixture.sendSigned(stranger)
        #expect(response.status == 401)
        #expect(errorCode(response) == "unauthorized")
    }

    @Test(
        "A duplicated signing header is unauthorized",
        arguments: ["X-Scriberman-Client", "X-Scriberman-Timestamp", "X-Scriberman-Nonce", "X-Scriberman-Body-SHA256", "X-Scriberman-Signature"]
    )
    func duplicateHeader(name: String) async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let headers = signer.headers(method: "GET", target: "/v1/prompts", timestamp: fixture.now)
        let duplicate = try #require(headers.first { $0.0 == name })
        let response = await fixture.send(fixture.head("GET", "/v1/prompts", headers: headers + [(name.lowercased(), duplicate.1)]))
        #expect(response.status == 401)
        #expect(errorCode(response) == "unauthorized")
    }

    @Test(
        "A missing signing header is unauthorized",
        arguments: ["X-Scriberman-Client", "X-Scriberman-Timestamp", "X-Scriberman-Nonce", "X-Scriberman-Body-SHA256", "X-Scriberman-Signature"]
    )
    func missingHeader(name: String) async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let headers = signer.headers(method: "GET", target: "/v1/prompts", timestamp: fixture.now).filter { $0.0 != name }
        let response = await fixture.send(fixture.head("GET", "/v1/prompts", headers: headers))
        #expect(response.status == 401)
        #expect(errorCode(response) == "unauthorized")
    }

    @Test("Signing checks run in admit, before any body is read")
    func checksInAdmit() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let headers = signer.headers(method: "GET", target: "/v1/prompts", timestamp: fixture.now.addingTimeInterval(-600))
        let admission = await fixture.handler.admit(fixture.head("GET", "/v1/prompts", headers: headers), peer: fixture.peer)
        guard case .refused(let response) = admission else {
            Issue.record("admitted")
            return
        }
        #expect(errorCode(response) == "stale_request")
    }

    // MARK: - Body limits

    @Test("A signed import up to 1 GiB is admitted with the import limit")
    func importAtLimit() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let headers = signer.headers(method: "POST", target: "/v1/imports", timestamp: fixture.now)
        let admission = await fixture.handler.admit(
            fixture.head("POST", "/v1/imports", headers: headers, contentLength: 1024 * 1024 * 1024),
            peer: fixture.peer
        )
        #expect(admission == .admitted(bodyLimit: 1024 * 1024 * 1024))
    }

    @Test("A signed import over 1 GiB is payload_too_large")
    func importOverLimit() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let headers = signer.headers(method: "POST", target: "/v1/imports", timestamp: fixture.now)
        let response = await fixture.send(fixture.head("POST", "/v1/imports", headers: headers, contentLength: 1024 * 1024 * 1024 + 1))
        #expect(response.status == 413)
        #expect(errorCode(response) == "payload_too_large")
    }

    @Test("A signed request to another route over 1 MiB is payload_too_large")
    func otherRouteOverLimit() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let headers = signer.headers(method: "POST", target: "/v1/recordings", timestamp: fixture.now)
        let response = await fixture.send(fixture.head("POST", "/v1/recordings", headers: headers, contentLength: 1024 * 1024 + 1))
        #expect(errorCode(response) == "payload_too_large")
    }

    // MARK: - Caller verifier

    @Test("A signed request asks the caller verifier with the identity recorded at pairing")
    func verifierInAdmit() async throws {
        let fixture = ExtensionAPIFixture()
        let identity = ExtensionAPICallerIdentity(designatedRequirement: "identifier \"recorded\"")
        fixture.verifier.pairingIdentity = identity
        let signer = try await fixture.pair()
        fixture.verifier.pairingIdentity = ExtensionAPICallerIdentity(designatedRequirement: "identifier \"later\"")

        _ = await fixture.sendSigned(signer)
        #expect(fixture.verifier.verifyCalls == [identity])
    }

    @Test("A signed request from a caller the verifier refuses is forbidden_caller")
    func verifierRefuses() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        fixture.verifier.acceptsRequests = false
        let response = await fixture.sendSigned(signer)
        #expect(response.status == 403)
        #expect(errorCode(response) == "forbidden_caller")
    }

    // MARK: - Keychain

    @Test("A Keychain read failure is treated as an unknown client, and the client stays listed")
    func keychainReadFailure() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        fixture.keychain.failsReads = true

        let response = await fixture.sendSigned(signer)
        #expect(response.status == 401)
        #expect(errorCode(response) == "unauthorized")
        #expect(fixture.store.clients.map(\.id) == [signer.clientID])

        fixture.keychain.failsReads = false
        #expect(await fixture.sendSigned(signer).status == 200)
    }

    @Test("A listed client with no secret in the Keychain is unauthorized and removed")
    func missingSecret() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let other = try await fixture.pair()
        for key in fixture.keychain.storage.keys where fixture.keychain.storage[key] == ExtensionAPITestSigner.hex(signer.secret) {
            fixture.keychain.removeOutsideStore(key: key)
        }

        let response = await fixture.sendSigned(signer)
        #expect(errorCode(response) == "unauthorized")
        #expect(fixture.store.clients.map(\.id) == [other.clientID])
    }

    // MARK: - Revocation

    @Test("A revoked client's next request is unauthorized and its secret leaves the Keychain")
    func revokeNextRequest() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        #expect(await fixture.sendSigned(signer).status == 200)

        fixture.store.revoke(signer.clientID)
        let response = await fixture.sendSigned(signer)
        #expect(response.status == 401)
        #expect(errorCode(response) == "unauthorized")
        #expect(!fixture.keychain.storage.values.contains(ExtensionAPITestSigner.hex(signer.secret)))
    }

    @Test("Revoking one client leaves the others working")
    func revokeOne() async throws {
        let fixture = ExtensionAPIFixture()
        let revoked = try await fixture.pair()
        let kept = try await fixture.pair()
        fixture.store.revoke(revoked.clientID)
        #expect(await fixture.sendSigned(kept).status == 200)
    }

    @Test("A client is revoked even when its Keychain secret can't be deleted")
    func revokeWithDeleteFailure() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        fixture.keychain.failsDeletes = true

        fixture.store.revoke(signer.clientID)
        #expect(fixture.store.clients.isEmpty)
        #expect(errorCode(await fixture.sendSigned(signer)) == "unauthorized")
    }

    @Test("A client revoked while its request is suspended gets unauthorized")
    func revokeDuringSuspension() async throws {
        let fixture = ExtensionAPIFixture()
        fixture.prompts = [AIPrompt(name: "Summary", content: "x")]
        let signer = try await fixture.pair()

        var release: CheckedContinuation<Void, Never>?
        var suspended = false
        fixture.promptsGate = {
            await withCheckedContinuation { continuation in
                release = continuation
                suspended = true
            }
        }
        let nonce = ExtensionAPITestSigner.randomNonce()
        let task = Task { @MainActor in await fixture.sendSigned(signer, nonce: nonce) }
        while !suspended {
            await Task.yield()
        }
        fixture.store.revoke(signer.clientID)
        release?.resume()
        let response = await task.value

        #expect(response.status == 401)
        #expect(errorCode(response) == "unauthorized")
        #expect(!String(decoding: response.body, as: UTF8.self).contains("Summary"))
        #expect(signer.verifies(response, nonce: nonce))
    }

    @Test("A client revoked between admit and handle gets unauthorized")
    func revokeBetweenAdmitAndHandle() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let headers = signer.headers(method: "GET", target: "/v1/prompts", timestamp: fixture.now)
        let head = fixture.head("GET", "/v1/prompts", headers: headers)
        #expect(await fixture.handler.admit(head, peer: fixture.peer) == .admitted(bodyLimit: ExtensionAPIHandler.defaultBodyLimit))

        fixture.store.revoke(signer.clientID)
        let response = await fixture.handler.handle(head, body: Data(), peer: fixture.peer)
        #expect(errorCode(response) == "unauthorized")
    }
}
