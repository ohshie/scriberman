import Foundation

/// The error codes of API contract v1.
enum ExtensionAPIErrorCode: String, Sendable, CaseIterable {
    case invalidRequest = "invalid_request"
    case notFoundRoute = "not_found_route"
    case unsupportedVersion = "unsupported_version"
    case forbiddenHost = "forbidden_host"
    case forbiddenOrigin = "forbidden_origin"
    case unauthorized
    case badSignature = "bad_signature"
    case staleRequest = "stale_request"
    case replayedRequest = "replayed_request"
    case forbiddenCaller = "forbidden_caller"
    case payloadTooLarge = "payload_too_large"
    case insufficientDiskSpace = "insufficient_disk_space"
    case pairingBusy = "pairing_busy"
    case pairingDenied = "pairing_denied"
    case pairingExpired = "pairing_expired"
    case alreadyRecording = "already_recording"
    case notRecording = "not_recording"
    case workspaceUnavailable = "workspace_unavailable"
    case modelsMissing = "models_missing"
    case permissionMissing = "permission_missing"
    case eventUnavailable = "event_unavailable"
    case notFound = "not_found"
    case unknownTag = "unknown_tag"
    case tagNotAssignable = "tag_not_assignable"
    case tooManyTags = "too_many_tags"
    case noTranscript = "no_transcript"
    case aiNotConfigured = "ai_not_configured"
    case transformationRunning = "transformation_running"
    case notAudio = "not_audio"
    case invalidFileName = "invalid_file_name"
    case importNotRecorded = "import_not_recorded"
}

/// What `admit` decided from the head alone.
enum ExtensionAPIAdmission: Equatable, Sendable {
    /// Read at most `bodyLimit` bytes of body, then call `handle`.
    case admitted(bodyLimit: Int)
    /// Send this response without reading the body, and close.
    case refused(HTTPResponse)
}

/// What the listener needs from the handler. The handler has no socket code; the listener has no
/// routing or checks.
protocol ExtensionAPIRequestHandling: Sendable {
    func admit(_ head: HTTPRequestHead, peer: ExtensionAPIPeer) async -> ExtensionAPIAdmission
    /// Runs the route. The listener cancels the calling task when the client disconnects.
    func handle(_ head: HTTPRequestHead, body: Data, peer: ExtensionAPIPeer) async -> HTTPResponse
    /// Called when the API stops listening, so held requests end.
    func apiDidStop() async
}

/// Takes a parsed request and returns a response. `admit` runs every check that needs only the
/// request line and headers, so nothing is read from a request that will be refused.
@MainActor
final class ExtensionAPIHandler: ExtensionAPIRequestHandling {
    static let defaultBodyLimit = 1024 * 1024
    static let importBodyLimit = 1024 * 1024 * 1024
    /// How far a request timestamp may be from the clock.
    static let clockWindow: TimeInterval = 60
    /// How long a nonce is remembered.
    static let nonceMemory: TimeInterval = 120

    /// Shows pairing requests. Without one, pairing is denied.
    weak var pairingPresenter: (any ExtensionAPIPairingPresenter)?

    private let port: @MainActor () -> Int
    private let pairingStore: ExtensionAPIPairingStore
    private let callerVerifier: any ExtensionAPICallerVerifier
    private let now: @MainActor () -> Date
    private let waitForPairingExpiry: @MainActor () async -> Void
    private let loadPrompts: @MainActor () async -> [AIPrompt]

    /// Nonces seen per client, with the time each was seen.
    private var seenNonces: [String: Date] = [:]
    private var pendingPairing: PendingPairing?

    private enum PairingOutcome {
        case approved
        case denied
        case expired
        case ended
    }

    private struct PendingPairing {
        let request: ExtensionAPIPairingRequest
        let continuation: CheckedContinuation<PairingOutcome, Never>
        var expiry: Task<Void, Never>?
    }

    init(
        port: @escaping @MainActor () -> Int,
        pairingStore: ExtensionAPIPairingStore,
        callerVerifier: any ExtensionAPICallerVerifier = CodeSigningCallerVerifier(),
        now: @escaping @MainActor () -> Date = { Date() },
        waitForPairingExpiry: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(120)) },
        loadPrompts: @escaping @MainActor () async -> [AIPrompt]
    ) {
        self.port = port
        self.pairingStore = pairingStore
        self.callerVerifier = callerVerifier
        self.now = now
        self.waitForPairingExpiry = waitForPairingExpiry
        self.loadPrompts = loadPrompts
    }

    func admit(_ head: HTTPRequestHead, peer: ExtensionAPIPeer) async -> ExtensionAPIAdmission {
        let hosts = head.values(for: "Host")
        let port = port()
        guard hosts.count == 1, hosts[0] == "127.0.0.1:\(port)" || hosts[0] == "localhost:\(port)" else {
            return .refused(Self.error(.forbiddenHost, status: 403))
        }
        guard head.values(for: "Origin").isEmpty else {
            return .refused(Self.error(.forbiddenOrigin, status: 403))
        }

        let route: ExtensionAPIRoute
        switch ExtensionAPIRoute.match(method: head.method, path: head.path) {
        case .found(let found):
            route = found
        case .unsupportedVersion:
            return .refused(Self.error(.unsupportedVersion, status: 404))
        case .notFound:
            return .refused(Self.error(.notFoundRoute, status: 404))
        case .methodNotAllowed(let allowed):
            let allow = HTTPRequestHead.Header(name: "Allow", value: allowed.joined(separator: ", "))
            return .refused(Self.error(.invalidRequest, status: 405, extraHeaders: [allow]))
        }

        var signing: RequestSigning?
        if route == .pair {
            guard await callerVerifier.identityForPairing(peer) != nil else {
                return .refused(Self.error(.forbiddenCaller, status: 403))
            }
        } else {
            switch authenticate(head) {
            case .refused(let response):
                return .refused(response)
            case .authenticated(let authenticated):
                signing = authenticated
            }
            guard await callerVerifier.verify(peer, matches: signing!.credentials.client.callerIdentity) else {
                return .refused(signing!.sign(Self.error(.forbiddenCaller, status: 403)))
            }
        }

        let limit = route == .imports ? Self.importBodyLimit : Self.defaultBodyLimit
        guard head.contentLength <= limit else {
            let response = Self.error(.payloadTooLarge, status: 413)
            return .refused(signing?.sign(response) ?? response)
        }
        return .admitted(bodyLimit: limit)
    }

    func handle(_ head: HTTPRequestHead, body: Data, peer: ExtensionAPIPeer) async -> HTTPResponse {
        guard case .found(let route) = ExtensionAPIRoute.match(method: head.method, path: head.path) else {
            return Self.error(.notFoundRoute, status: 404)
        }
        if route == .pair {
            return await pair(body: body, peer: peer)
        }

        // The client may have been revoked since `admit`.
        guard let signing = signingOfAdmittedRequest(head) else {
            return Self.error(.unauthorized, status: 401)
        }
        guard ExtensionAPISigning.sha256Hex(body) == signing.bodyHash else {
            return signing.sign(Self.error(.badSignature, status: 401))
        }
        return signing.sign(await respond(to: route, signing: signing))
    }

    func apiDidStop() async {
        resolvePairing(pendingPairing?.request.id, as: .ended)
    }

    /// Nil when the client is still paired; otherwise the `unauthorized` response to send. Routes
    /// call it after every suspension, before they change anything or write a file.
    func revocationResponse(for signing: RequestSigning) -> HTTPResponse? {
        pairingStore.isPaired(signing.credentials.client.id) ? nil : Self.error(.unauthorized, status: 401)
    }

    // MARK: - Routes

    private func respond(to route: ExtensionAPIRoute, signing: RequestSigning) async -> HTTPResponse {
        switch route {
        case .prompts:
            let prompts = await loadPrompts()
            if let revoked = revocationResponse(for: signing) { return revoked }
            return Self.json(PromptList(prompts: prompts.map { .init(id: $0.id.uuidString, name: $0.name) }))
        default:
            // Each remaining route arrives with its own ticket.
            return Self.error(.notFoundRoute, status: 404)
        }
    }

    private struct PromptList: Encodable {
        struct Prompt: Encodable {
            let id: String
            let name: String
        }

        let prompts: [Prompt]
    }

    // MARK: - Signing

    /// A request whose client, timestamp, nonce and head signature checked out.
    struct RequestSigning {
        let credentials: ExtensionAPIClientCredentials
        let nonce: String
        let bodyHash: String

        func sign(_ response: HTTPResponse) -> HTTPResponse {
            ExtensionAPISigning.sign(response, nonce: nonce, secret: credentials.secret)
        }
    }

    private enum Authentication {
        case authenticated(RequestSigning)
        case refused(HTTPResponse)
    }

    private func signingHeaders(_ head: HTTPRequestHead) -> [String: String]? {
        var values: [String: String] = [:]
        for name in ExtensionAPISigning.requestHeaders {
            let found = head.values(for: name)
            guard found.count == 1 else { return nil }
            values[name] = found[0]
        }
        return values
    }

    private func authenticate(_ head: HTTPRequestHead) -> Authentication {
        let unauthorized = Authentication.refused(Self.error(.unauthorized, status: 401))
        guard let headers = signingHeaders(head),
              let clientID = headers[ExtensionAPISigning.clientHeader],
              let credentials = pairingStore.credentials(for: clientID)
        else {
            return unauthorized
        }
        let nonce = headers[ExtensionAPISigning.nonceHeader]!
        guard ExtensionAPISigning.isHex(nonce, byteCount: 16) else {
            return unauthorized
        }
        let signing = RequestSigning(credentials: credentials, nonce: nonce, bodyHash: headers[ExtensionAPISigning.bodyHashHeader]!)
        let refuse = { (code: ExtensionAPIErrorCode) in Authentication.refused(signing.sign(Self.error(code, status: 401))) }

        let timestampText = headers[ExtensionAPISigning.timestampHeader]!
        guard ExtensionAPISigning.isHex(signing.bodyHash, byteCount: 32),
              !timestampText.isEmpty, timestampText.utf8.allSatisfy({ (48...57).contains($0) }),
              let timestamp = TimeInterval(timestampText)
        else {
            return refuse(.unauthorized)
        }
        let now = now()
        guard abs(now.timeIntervalSince1970 - timestamp) <= Self.clockWindow else {
            return refuse(.staleRequest)
        }
        seenNonces = seenNonces.filter { now.timeIntervalSince($0.value) < Self.nonceMemory }
        let nonceKey = clientID + " " + nonce
        guard seenNonces[nonceKey] == nil else {
            return refuse(.replayedRequest)
        }
        guard ExtensionAPISigning.isValidRequestSignature(
            headers[ExtensionAPISigning.signatureHeader]!,
            method: head.method,
            target: head.target,
            timestamp: timestampText,
            nonce: nonce,
            bodyHash: signing.bodyHash,
            secret: credentials.secret
        ) else {
            return refuse(.badSignature)
        }
        // Only a correctly signed request uses up its nonce, so forged requests can't burn one.
        seenNonces[nonceKey] = now
        return .authenticated(signing)
    }

    /// The signing of a request `admit` already accepted, read again for `handle`.
    private func signingOfAdmittedRequest(_ head: HTTPRequestHead) -> RequestSigning? {
        guard let headers = signingHeaders(head),
              let credentials = pairingStore.credentials(for: headers[ExtensionAPISigning.clientHeader]!)
        else {
            return nil
        }
        return RequestSigning(
            credentials: credentials,
            nonce: headers[ExtensionAPISigning.nonceHeader]!,
            bodyHash: headers[ExtensionAPISigning.bodyHashHeader]!
        )
    }

    // MARK: - Pairing

    private struct PairBody: Decodable {
        let name: String
    }

    private struct PairResponse: Encodable {
        let clientId: String
        let secret: String
    }

    private func pair(body: Data, peer: ExtensionAPIPeer) async -> HTTPResponse {
        guard let name = (try? JSONDecoder().decode(PairBody.self, from: body))?.name else {
            return Self.error(.invalidRequest, status: 400)
        }
        guard pendingPairing == nil else {
            return Self.error(.pairingBusy, status: 409)
        }
        guard let identity = await callerVerifier.identityForPairing(peer) else {
            return Self.error(.forbiddenCaller, status: 403)
        }
        guard let presenter = pairingPresenter else {
            return Self.error(.pairingDenied, status: 403)
        }
        // Another request may have started while the verifier ran.
        guard pendingPairing == nil else {
            return Self.error(.pairingBusy, status: 409)
        }

        let request = ExtensionAPIPairingRequest(id: UUID(), claimedName: name)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<PairingOutcome, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .ended)
                    return
                }
                pendingPairing = PendingPairing(request: request, continuation: continuation)
                pendingPairing?.expiry = Task { [weak self, waitForPairingExpiry] in
                    await waitForPairingExpiry()
                    guard !Task.isCancelled else { return }
                    self?.resolvePairing(request.id, as: .expired)
                }
                presenter.present(request) { [weak self] decision in
                    self?.resolvePairing(request.id, as: decision == .approve ? .approved : .denied)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolvePairing(request.id, as: .ended)
            }
        }

        switch outcome {
        case .approved:
            do {
                let credentials = try pairingStore.pair(name: name, callerIdentity: identity, at: now())
                return Self.json(PairResponse(
                    clientId: credentials.client.id,
                    secret: ExtensionAPISigning.hex(credentials.secret)
                ))
            } catch {
                return Self.error(.pairingDenied, status: 500)
            }
        case .denied, .ended:
            return Self.error(.pairingDenied, status: 403)
        case .expired:
            return Self.error(.pairingExpired, status: 408)
        }
    }

    /// Ends the pending pairing with `outcome` if it is still the one with `id`. Approval, denial,
    /// expiry, disconnect and stop all come through here on the main actor, so exactly one wins.
    private func resolvePairing(_ id: UUID?, as outcome: PairingOutcome) {
        guard let pending = pendingPairing, pending.request.id == id else { return }
        pendingPairing = nil
        pending.expiry?.cancel()
        if outcome == .expired || outcome == .ended {
            pairingPresenter?.withdraw(pending.request)
        }
        pending.continuation.resume(returning: outcome)
    }

    // MARK: - Responses

    /// The answer to a request that could not be framed.
    nonisolated static func response(for error: HTTPFramingError) -> HTTPResponse {
        Self.error(.invalidRequest, status: 400)
    }

    nonisolated static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [.init(name: "Content-Type", value: "application/json; charset=utf-8")],
            body: (try? JSONEncoder().encode(value)) ?? Data()
        )
    }

    /// An error response with the `{code, message}` body of the API contract. The message text
    /// is the code until the maintainer supplies wording.
    nonisolated static func error(
        _ code: ExtensionAPIErrorCode,
        status: Int,
        extraHeaders: [HTTPRequestHead.Header] = []
    ) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(["code": code.rawValue, "message": code.rawValue])) ?? Data()
        return HTTPResponse(
            status: status,
            headers: [.init(name: "Content-Type", value: "application/json; charset=utf-8")] + extraHeaders,
            body: body
        )
    }
}

/// The routes of API contract v1.
enum ExtensionAPIRoute: Equatable, Sendable, CaseIterable {
    case pair
    case status
    case captureOptions
    case quickStart
    case startRecording
    case calendarSuggestions
    case startFromCalendar
    case stopRecording
    case updateCurrentRecording
    case sessions
    case latestSession
    case session
    case openSession
    case exportSession
    case revealSession
    case prompts
    case runTransformation
    case operation
    case imports

    enum Match: Equatable {
        case found(ExtensionAPIRoute)
        case methodNotAllowed(allowed: [String])
        case notFound
        case unsupportedVersion
    }

    static let version = "v1"

    var method: String {
        switch self {
        case .status, .captureOptions, .calendarSuggestions, .sessions, .latestSession, .session, .prompts, .operation:
            "GET"
        case .updateCurrentRecording:
            "PATCH"
        case .pair, .quickStart, .startRecording, .startFromCalendar, .stopRecording, .openSession, .exportSession,
             .revealSession, .runTransformation, .imports:
            "POST"
        }
    }

    /// Path segments after the version; `nil` stands for one id segment.
    private var pattern: [String?] {
        switch self {
        case .pair: ["pair"]
        case .status: ["status"]
        case .captureOptions: ["capture-options"]
        case .quickStart: ["recordings", "quick-start"]
        case .startRecording: ["recordings"]
        case .calendarSuggestions: ["calendar", "suggestions"]
        case .startFromCalendar: ["recordings", "from-calendar"]
        case .stopRecording: ["recordings", "stop"]
        case .updateCurrentRecording: ["recordings", "current"]
        case .sessions: ["sessions"]
        case .latestSession: ["sessions", "latest"]
        case .session: ["sessions", nil]
        case .openSession: ["sessions", nil, "open"]
        case .exportSession: ["sessions", nil, "export"]
        case .revealSession: ["sessions", nil, "reveal"]
        case .prompts: ["prompts"]
        case .runTransformation: ["sessions", nil, "transformations"]
        case .operation: ["operations", nil]
        case .imports: ["imports"]
        }
    }

    private func matches(_ segments: [Substring]) -> Bool {
        guard segments.count == pattern.count else { return false }
        return zip(pattern, segments).allSatisfy { expected, segment in
            expected.map { $0 == segment } ?? !segment.isEmpty
        }
    }

    static func match(method: String, path: String) -> Match {
        var segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard let version = segments.first, isVersionSegment(version) else {
            return .notFound
        }
        guard version == Self.version else {
            return .unsupportedVersion
        }
        segments = segments.dropFirst()
        let rest = Array(segments)
        // A literal segment wins over an id segment, so `/sessions/latest` is not a session id.
        let candidates = allCases.filter { $0.matches(rest) }
        let literal = candidates.filter { !$0.pattern.contains(nil) }
        let pathMatches = literal.isEmpty ? candidates : literal
        guard !pathMatches.isEmpty else {
            return .notFound
        }
        if let route = pathMatches.first(where: { $0.method == method }) {
            return .found(route)
        }
        return .methodNotAllowed(allowed: pathMatches.map(\.method))
    }

    private static func isVersionSegment(_ segment: Substring) -> Bool {
        segment.count > 1 && segment.first == "v" && segment.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }
}
