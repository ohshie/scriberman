import Foundation
import Testing
@testable import Scriberman

@MainActor
struct ExtensionAPIHandlerTests {
    private struct ErrorBody: Decodable, Equatable {
        let code: String
        let message: String
    }

    private func makeHandler(port: Int = 47615) -> ExtensionAPIHandler {
        ExtensionAPIHandler(
            port: { port },
            pairingStore: ExtensionAPIPairingStore(
                defaults: UserDefaults(suiteName: "ExtensionAPIHandlerTests-\(UUID().uuidString)")!,
                keychain: MockKeychainStore()
            ),
            callerVerifier: FakeCallerVerifier(),
            loadPrompts: { [] }
        )
    }

    private let peer = ExtensionAPIPeer(endpoint: nil)

    private func head(
        _ method: String = "POST",
        _ target: String = "/v1/pair",
        headers: [(String, String)] = [("Host", "127.0.0.1:47615")],
        contentLength: Int = 0
    ) -> HTTPRequestHead {
        HTTPRequestHead(
            method: method,
            target: target,
            headers: headers.map { .init(name: $0.0, value: $0.1) },
            contentLength: contentLength
        )
    }

    /// The status and error code a refusal carries, or nil when the request was admitted.
    private func refusal(_ admission: ExtensionAPIAdmission) throws -> (status: Int, code: String)? {
        guard case .refused(let response) = admission else { return nil }
        let body = try JSONDecoder().decode(ErrorBody.self, from: response.body)
        return (response.status, body.code)
    }

    // MARK: - Host

    @Test("A request to /v1/pair with a loopback Host is admitted", arguments: ["127.0.0.1:47615", "localhost:47615"])
    func loopbackHostAdmitted(host: String) async throws {
        let admission = await makeHandler().admit(head(headers: [("Host", host)]), peer: peer)
        #expect(try refusal(admission) == nil)
    }

    @Test(
        "A Host other than 127.0.0.1 or localhost on the configured port is refused",
        arguments: [
            "127.0.0.1:47616", "localhost:80", "127.0.0.1", "localhost", "evil.example:47615",
            "127.0.0.1.evil.example:47615", "[::1]:47615", "0.0.0.0:47615", "127.0.0.1:47615 ", "",
            "LOCALHOST:47615", "127.0.0.1:047615",
        ]
    )
    func wrongHostRefused(host: String) async throws {
        let admission = await makeHandler().admit(head(headers: [("Host", host)]), peer: peer)
        let result = try #require(try refusal(admission))
        #expect(result.status == 403)
        #expect(result.code == "forbidden_host")
    }

    @Test("A request without Host is refused")
    func missingHostRefused() async throws {
        let result = try #require(try refusal(await makeHandler().admit(head(headers: []), peer: peer)))
        #expect(result.status == 403)
        #expect(result.code == "forbidden_host")
    }

    @Test("Two Host headers are refused even when both are valid")
    func duplicateHostRefused() async throws {
        let headers = [("Host", "127.0.0.1:47615"), ("host", "127.0.0.1:47615")]
        let result = try #require(try refusal(await makeHandler().admit(head(headers: headers), peer: peer)))
        #expect(result.status == 403)
        #expect(result.code == "forbidden_host")
    }

    @Test("The Host check follows the configured port")
    func hostFollowsPort() async throws {
        let handler = makeHandler(port: 50000)
        #expect(try refusal(await handler.admit(head(headers: [("Host", "127.0.0.1:50000")]), peer: peer)) == nil)
        #expect(try refusal(await handler.admit(head(headers: [("Host", "127.0.0.1:47615")]), peer: peer))?.code == "forbidden_host")
    }

    // MARK: - Origin

    @Test(
        "Any Origin header is refused, including null in any case",
        arguments: [
            ("Origin", "null"), ("Origin", "NULL"), ("Origin", "Null"), ("ORIGIN", "null"), ("origin", ""),
            ("Origin", "http://127.0.0.1:47615"), ("Origin", "https://evil.example"),
        ]
    )
    func originRefused(name: String, value: String) async throws {
        let headers = [("Host", "127.0.0.1:47615"), (name, value)]
        let result = try #require(try refusal(await makeHandler().admit(head(headers: headers), peer: peer)))
        #expect(result.status == 403)
        #expect(result.code == "forbidden_origin")
    }

    @Test("The Host check runs before the Origin check")
    func hostBeforeOrigin() async throws {
        let headers = [("Host", "evil.example"), ("Origin", "null")]
        #expect(try refusal(await makeHandler().admit(head(headers: headers), peer: peer))?.code == "forbidden_host")
    }

    // MARK: - Routes

    @Test("An unknown path under /v1 is not_found_route", arguments: ["/v1/nope", "/v1", "/v1/", "/v1/status/extra", "/v1/sessions/a/b"])
    func unknownRoute(target: String) async throws {
        let result = try #require(try refusal(await makeHandler().admit(head("GET", target), peer: peer)))
        #expect(result.status == 404)
        #expect(result.code == "not_found_route")
    }

    @Test("A path outside any version is not_found_route", arguments: ["/", "/status", "/api/v1/status"])
    func unversionedRoute(target: String) async throws {
        let result = try #require(try refusal(await makeHandler().admit(head("GET", target), peer: peer)))
        #expect(result.status == 404)
        #expect(result.code == "not_found_route")
    }

    @Test("A path under another version is unsupported_version", arguments: ["/v2/status", "/v0/pair", "/v10/sessions"])
    func otherVersion(target: String) async throws {
        let result = try #require(try refusal(await makeHandler().admit(head("GET", target), peer: peer)))
        #expect(result.status == 404)
        #expect(result.code == "unsupported_version")
    }

    @Test("A known path with an unsupported method is 405 and lists the allowed methods")
    func wrongMethod() async throws {
        let admission = await makeHandler().admit(head("DELETE", "/v1/status"), peer: peer)
        guard case .refused(let response) = admission else {
            Issue.record("admitted")
            return
        }
        #expect(response.status == 405)
        #expect(response.headers.contains(.init(name: "Allow", value: "GET")))
        #expect(try JSONDecoder().decode(ErrorBody.self, from: response.body).code == "invalid_request")
    }

    @Test(
        "An unsigned request to any /v1 route except /v1/pair is unauthorized",
        arguments: [
            ("GET", "/v1/status"), ("GET", "/v1/capture-options"), ("POST", "/v1/recordings/quick-start"),
            ("POST", "/v1/recordings"), ("GET", "/v1/calendar/suggestions"), ("POST", "/v1/recordings/from-calendar"),
            ("POST", "/v1/recordings/stop"), ("PATCH", "/v1/recordings/current"), ("GET", "/v1/sessions?q=a"),
            ("GET", "/v1/sessions/latest"), ("GET", "/v1/sessions/recording:1"), ("POST", "/v1/sessions/x/open"),
            ("POST", "/v1/sessions/x/export"), ("POST", "/v1/sessions/x/reveal"), ("GET", "/v1/prompts"),
            ("POST", "/v1/sessions/x/transformations"), ("GET", "/v1/operations/x"), ("POST", "/v1/imports"),
        ]
    )
    func unsignedUnauthorized(method: String, target: String) async throws {
        let result = try #require(try refusal(await makeHandler().admit(head(method, target), peer: peer)))
        #expect(result.status == 401)
        #expect(result.code == "unauthorized")
    }

    // MARK: - Body limits

    @Test("A body of 1 MiB on /v1/pair is admitted")
    func bodyAtLimit() async throws {
        let admission = await makeHandler().admit(head(contentLength: 1024 * 1024), peer: peer)
        #expect(try refusal(admission) == nil)
    }

    @Test("A body over 1 MiB on /v1/pair is refused before it is read")
    func bodyOverLimit() async throws {
        let result = try #require(try refusal(await makeHandler().admit(head(contentLength: 1024 * 1024 + 1), peer: peer)))
        #expect(result.status == 413)
        #expect(result.code == "payload_too_large")
    }

    // MARK: - Responses

    @Test("A refusal is a JSON body with code and message")
    func errorBodyShape() async throws {
        let admission = await makeHandler().admit(head(headers: []), peer: peer)
        guard case .refused(let response) = admission else {
            Issue.record("admitted")
            return
        }
        #expect(response.headers.contains(.init(name: "Content-Type", value: "application/json; charset=utf-8")))
        let object = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: String])
        #expect(Set(object.keys) == ["code", "message"])
    }

    @Test("A framing error is 400 invalid_request")
    func framingError() throws {
        let response = ExtensionAPIHandler.response(for: HTTPFramingError.transferEncodingNotSupported)
        #expect(response.status == 400)
        #expect(try JSONDecoder().decode(ErrorBody.self, from: response.body).code == "invalid_request")
    }
}
