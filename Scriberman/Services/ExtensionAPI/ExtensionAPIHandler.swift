import Foundation
import SwiftData

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
    /// Capture did not start for a reason the readiness check does not cover.
    case captureFailed = "capture_failed"
    /// The store refused a change; nothing was changed.
    case saveFailed = "save_failed"
}

/// What `admit` decided from the head alone.
enum ExtensionAPIAdmission: Equatable, Sendable {
    /// Read at most `bodyLimit` bytes of body, then call `handle`.
    case admitted(bodyLimit: Int)
    /// Write the body to this staged file, then call `handleUpload`. The listener discards the
    /// upload if the request ends before that.
    case admittedToFile(ExtensionAPIStagedUpload)
    /// Send this response without reading the body, and close.
    case refused(HTTPResponse)
}

/// What the listener needs from the handler. The handler has no socket code; the listener has no
/// routing or checks.
protocol ExtensionAPIRequestHandling: Sendable {
    func admit(_ head: HTTPRequestHead, peer: ExtensionAPIPeer) async -> ExtensionAPIAdmission
    /// Runs the route. The listener cancels the calling task when the client disconnects.
    func handle(_ head: HTTPRequestHead, body: Data, peer: ExtensionAPIPeer) async -> HTTPResponse
    /// Runs a route whose body was staged to a file. The handler owns `upload` from here on.
    func handleUpload(_ head: HTTPRequestHead, upload: ExtensionAPIStagedUpload, peer: ExtensionAPIPeer) async -> HTTPResponse
    /// Called when the API stops listening, so held requests end.
    func apiDidStop() async
}

extension ExtensionAPIRequestHandling {
    func handleUpload(_ head: HTTPRequestHead, upload: ExtensionAPIStagedUpload, peer: ExtensionAPIPeer) async -> HTTPResponse {
        upload.discard()
        return ExtensionAPIHandler.error(.notFoundRoute, status: 404)
    }
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
    /// Status, capture options, start and stop. Without it those routes answer `not_found_route`.
    var recording: ExtensionAPIRecording?
    /// Calendar suggestions and starting from one. Without it those routes answer `not_found_route`.
    var calendar: ExtensionAPICalendar?

    private let port: @MainActor () -> Int
    private let pairingStore: ExtensionAPIPairingStore
    private let callerVerifier: any ExtensionAPICallerVerifier
    private let now: @MainActor () -> Date
    private let waitForPairingExpiry: @MainActor () async -> Void
    private let loadPrompts: @MainActor () async -> [AIPrompt]
    private let sessions: ExtensionAPISessionCatalog
    private let importAudioFile: ImportAudioFile
    private let stagingDirectory: URL
    private let availableDiskSpace: @MainActor () -> Int64?
    private let makeStagingDirectory: @MainActor (URL) throws -> URL

    /// Imports one staged file and returns the new session's id. It calls the closure it is given
    /// once the session's conversion has finished or failed.
    typealias ImportAudioFile = @MainActor (URL, @escaping @Sendable () -> Void) async throws(SingleAudioImportError) -> UUID
    /// Where routes that name a session look it up. Nil finds no session.
    private let modelContext: ModelContext?
    private let transformationRunner: AITransformationRunner?

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
        loadPrompts: @escaping @MainActor () async -> [AIPrompt],
        sessions: ExtensionAPISessionCatalog,
        importAudioFile: @escaping ImportAudioFile = { _, _ throws(SingleAudioImportError) in throw .workspaceUnavailable },
        stagingDirectory: URL = FileManager.default.temporaryDirectory,
        availableDiskSpace: (@MainActor () -> Int64?)? = nil,
        makeStagingDirectory: @escaping @MainActor (URL) throws -> URL = { try ExtensionAPIStagedUpload.makeUniqueDirectory(in: $0) },
        modelContext: ModelContext? = nil,
        transformationRunner: AITransformationRunner? = nil
    ) {
        self.port = port
        self.pairingStore = pairingStore
        self.callerVerifier = callerVerifier
        self.now = now
        self.waitForPairingExpiry = waitForPairingExpiry
        self.loadPrompts = loadPrompts
        self.sessions = sessions
        self.importAudioFile = importAudioFile
        self.stagingDirectory = stagingDirectory
        self.availableDiskSpace = availableDiskSpace ?? {
            let values = try? stagingDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }
        self.makeStagingDirectory = makeStagingDirectory
        self.modelContext = modelContext
        self.transformationRunner = transformationRunner
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
        if route == .imports {
            switch stageImport(head) {
            case .success(let upload):
                return .admittedToFile(upload)
            case .failure(let refusal):
                return .refused(signing!.sign(refusal.response))
            }
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
        return signing.sign(await respond(to: route, body: body, signing: signing, head: head))
    }

    func handleUpload(_ head: HTTPRequestHead, upload: ExtensionAPIStagedUpload, peer: ExtensionAPIPeer) async -> HTTPResponse {
        // The client may have been revoked while the body arrived.
        guard let signing = signingOfAdmittedRequest(head) else {
            upload.discard()
            return Self.error(.unauthorized, status: 401)
        }
        guard upload.bodySHA256 == signing.bodyHash else {
            upload.discard()
            return signing.sign(Self.error(.badSignature, status: 401))
        }
        guard !upload.writeFailed else {
            upload.discard()
            return signing.sign(Self.error(.insufficientDiskSpace, status: 507))
        }
        guard !Task.isCancelled else {
            // The client is gone; nothing is sent.
            upload.discard()
            return Self.error(.invalidRequest, status: 400)
        }
        do {
            let sessionID = try await importAudioFile(upload.fileURL) { upload.discard() }
            return signing.sign(Self.json(ImportResponse(sessionId: "imported:\(sessionID.uuidString)"), status: 202))
        } catch {
            upload.discard()
            switch error {
            case .notAudio:
                return signing.sign(Self.error(.notAudio, status: 415))
            case .workspaceUnavailable:
                return signing.sign(Self.error(.workspaceUnavailable, status: 503))
            case .notRecorded:
                return signing.sign(Self.error(.importNotRecorded, status: 500))
            }
        }
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

    private func respond(to route: ExtensionAPIRoute, body: Data, signing: RequestSigning, head: HTTPRequestHead) async -> HTTPResponse {
        switch route {
        case .sessions:
            return listSessions(target: head.target)
        case .latestSession:
            guard let detail = sessions.latest() else { return Self.error(.notFound, status: 404) }
            return Self.json(detail)
        case .session:
            guard let id = Self.sessionID(inPath: head.path) else { return Self.error(.invalidRequest, status: 400) }
            guard let detail = sessions.detail(id) else { return Self.error(.notFound, status: 404) }
            return Self.json(detail)
        case .prompts:
            let prompts = await loadPrompts()
            if let revoked = revocationResponse(for: signing) { return revoked }
            return Self.json(PromptList(prompts: prompts.map { .init(id: $0.id.uuidString, name: $0.name) }))
        case .status, .captureOptions, .quickStart, .startRecording, .stopRecording, .updateCurrentRecording:
            guard let recording else { return Self.error(.notFoundRoute, status: 404) }
            return await respond(to: route, recording: recording, body: body, signing: signing)
        case .calendarSuggestions, .startFromCalendar:
            guard let calendar else { return Self.error(.notFoundRoute, status: 404) }
            let response = route == .calendarSuggestions ? await calendar.suggestions() : await calendar.start(body: body)
            return revocationResponse(for: signing) ?? response
        case .runTransformation:
            return await runTransformation(sessionID: route.idSegment(in: head.path), body: body, signing: signing)
        case .operation:
            return operation(route.idSegment(in: head.path))
        default:
            // Each remaining route arrives with its own ticket.
            return Self.error(.notFoundRoute, status: 404)
        }
    }

    private func respond(
        to route: ExtensionAPIRoute,
        recording: ExtensionAPIRecording,
        body: Data,
        signing: RequestSigning
    ) async -> HTTPResponse {
        let response: HTTPResponse
        switch route {
        case .status: response = recording.status()
        case .captureOptions: response = await recording.captureOptions()
        case .quickStart: response = await recording.quickStart()
        case .startRecording: response = await recording.start(body: body)
        case .stopRecording: response = await recording.stop()
        case .updateCurrentRecording: response = recording.updateCurrent(body: body)
        default: return Self.error(.notFoundRoute, status: 404)
        }
        return revocationResponse(for: signing) ?? response
    }

    private struct SessionList: Encodable {
        let sessions: [ExtensionAPISessionRow]
    }

    static let defaultSessionLimit = 50
    static let maximumSessionLimit = 200

    /// `GET /v1/sessions`: `q`, `tag`, `limit` and `offset`, each at most once.
    private func listSessions(target: String) -> HTTPResponse {
        let invalid = Self.error(.invalidRequest, status: 400)
        guard let components = URLComponents(string: target) else { return invalid }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil else { return invalid }
            values[item.name] = item.value ?? ""
        }

        var tagID: UUID?
        if let tag = values["tag"] {
            guard let parsed = UUID(uuidString: tag) else { return invalid }
            tagID = parsed
        }
        var limit = Self.defaultSessionLimit
        if let text = values["limit"] {
            guard let parsed = Self.nonNegativeInteger(text), (1...Self.maximumSessionLimit).contains(parsed) else {
                return invalid
            }
            limit = parsed
        }
        var offset = 0
        if let text = values["offset"] {
            guard let parsed = Self.nonNegativeInteger(text) else { return invalid }
            offset = parsed
        }
        return Self.json(SessionList(sessions: sessions.sessions(query: values["q"], tagID: tagID, limit: limit, offset: offset)))
    }

    private static func nonNegativeInteger(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(text)
    }

    /// The id segment of `/v1/sessions/{id}...`.
    private static func sessionID(inPath path: String) -> ExtensionAPISessionID? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count > 3 else { return nil }
        return ExtensionAPISessionID(pathSegment: String(segments[3]))
    }

    // MARK: - Imports

    static let fileNameHeader = "X-Scriberman-File-Name"

    private struct ImportResponse: Encodable {
        let sessionId: String
    }

    private struct Refusal: Error {
        let response: HTTPResponse
    }

    /// The checks an import needs before its body is read, then the staged file it is written to.
    private func stageImport(_ head: HTTPRequestHead) -> Result<ExtensionAPIStagedUpload, Refusal> {
        // The staged upload plus the converted audio.
        guard let available = availableDiskSpace(), available >= 2 * Int64(head.contentLength) else {
            return .failure(Refusal(response: Self.error(.insufficientDiskSpace, status: 507)))
        }
        let names = head.values(for: Self.fileNameHeader)
        guard names.count == 1, let name = Self.validatedFileName(names[0]) else {
            return .failure(Refusal(response: Self.error(.invalidFileName, status: 400)))
        }
        guard JobsViewModel.isAudioFileName(name) else {
            return .failure(Refusal(response: Self.error(.notAudio, status: 415)))
        }
        do {
            let directory = try makeStagingDirectory(stagingDirectory)
            return .success(try ExtensionAPIStagedUpload(directory: directory, name: name))
        } catch {
            return .failure(Refusal(response: Self.error(.insufficientDiskSpace, status: 507)))
        }
    }

    /// The decoded file name, or nil when it can't name a single file of its own.
    nonisolated static func validatedFileName(_ header: String) -> String? {
        guard let name = header.removingPercentEncoding,
              !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255
        else {
            return nil
        }
        return name
    }

    private struct PromptList: Encodable {
        struct Prompt: Encodable {
            let id: String
            let name: String
        }

        let prompts: [Prompt]
    }

    // MARK: - Transformations

    private struct TransformationBody: Decodable {
        let promptId: String
    }

    private struct OperationStarted: Encodable {
        let operationId: String
    }

    private struct OperationBody: Encodable {
        let state: String
        var transformationId: String?
        var code: String?
        var message: String?
    }

    private func runTransformation(sessionID: String, body: Data, signing: RequestSigning) async -> HTTPResponse {
        guard let request = try? JSONDecoder().decode(TransformationBody.self, from: body),
              let promptID = UUID(uuidString: request.promptId)
        else {
            return Self.error(.invalidRequest, status: 400)
        }
        let prompts = await loadPrompts()
        if let revoked = revocationResponse(for: signing) { return revoked }

        // Looked up after the suspension, so a session deleted meanwhile is not found.
        guard let runner = transformationRunner, let session = session(withID: sessionID) else {
            return Self.error(.notFound, status: 404)
        }
        guard let prompt = prompts.first(where: { $0.id == promptID }) else {
            return Self.error(.notFound, status: 404)
        }
        let operationID: UUID
        do {
            operationID = try runner.start(prompt: prompt, on: session)
        } catch {
            return Self.error(.transformationRunning, status: 409)
        }
        // A run whose requirements are unmet has already failed; those failures answer the request.
        if case .failed(let failure) = runner.state(of: operationID) {
            switch failure.code {
            case .aiNotConfigured:
                return Self.error(.aiNotConfigured, status: 409)
            case .noTranscript:
                return Self.error(.noTranscript, status: 409)
            case .providerFailed, .notFound, .saveFailed:
                break
            }
        }
        return Self.json(OperationStarted(operationId: operationID.uuidString), status: 202)
    }

    private func operation(_ id: String) -> HTTPResponse {
        guard let operationID = UUID(uuidString: id),
              let state = transformationRunner?.state(of: operationID)
        else {
            return Self.error(.notFound, status: 404)
        }
        switch state {
        case .running:
            return Self.json(OperationBody(state: "running"))
        case .succeeded(let transformationID):
            return Self.json(OperationBody(state: "succeeded", transformationId: transformationID.uuidString))
        case .failed(let failure):
            let code = Self.operationCode(failure.code)
            // Without an error description the message repeats the code, as error responses do.
            return Self.json(OperationBody(state: "failed", code: code, message: failure.message ?? code))
        }
    }

    private static func operationCode(_ code: AITransformationRunner.Failure.Code) -> String {
        switch code {
        case .aiNotConfigured: ExtensionAPIErrorCode.aiNotConfigured.rawValue
        case .noTranscript: ExtensionAPIErrorCode.noTranscript.rawValue
        case .notFound: ExtensionAPIErrorCode.notFound.rawValue
        case .providerFailed: "provider_failed"
        case .saveFailed: "save_failed"
        }
    }

    // MARK: - Sessions

    /// The session a kind-qualified id (`recording:<uuid>` or `imported:<uuid>`) names, or nil.
    private func session(withID id: String) -> (any TranscribableSession)? {
        guard let modelContext, let parsed = ExtensionAPISessionID(pathSegment: id) else { return nil }
        let uuid = parsed.uuid
        switch parsed.kind {
        case .recording:
            let descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.id == uuid })
            return try? modelContext.fetch(descriptor).first
        case .imported:
            let descriptor = FetchDescriptor<ImportedSession>(predicate: #Predicate { $0.id == uuid })
            return try? modelContext.fetch(descriptor).first
        }
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

    /// The id segment of `path`, for a route with one; empty when there is none.
    func idSegment(in path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst(2)
        guard let index = pattern.firstIndex(where: { $0 == nil }), index < segments.count else { return "" }
        return String(Array(segments)[index])
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
