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
    func admit(_ head: HTTPRequestHead) async -> ExtensionAPIAdmission
    func handle(_ head: HTTPRequestHead, body: Data) async -> HTTPResponse
}

/// Takes a parsed request and returns a response. `admit` runs every check that needs only the
/// request line and headers, so nothing is read from a request that will be refused.
@MainActor
final class ExtensionAPIHandler: ExtensionAPIRequestHandling {
    static let defaultBodyLimit = 1024 * 1024
    static let importBodyLimit = 1024 * 1024 * 1024

    private let port: @MainActor () -> Int

    init(port: @escaping @MainActor () -> Int) {
        self.port = port
    }

    func admit(_ head: HTTPRequestHead) async -> ExtensionAPIAdmission {
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

        // Pairing and request signing arrive with ticket 03. Until then only pairing gets past here.
        guard route == .pair else {
            return .refused(Self.error(.unauthorized, status: 401))
        }

        let limit = route == .imports ? Self.importBodyLimit : Self.defaultBodyLimit
        guard head.contentLength <= limit else {
            return .refused(Self.error(.payloadTooLarge, status: 413))
        }
        return .admitted(bodyLimit: limit)
    }

    func handle(_ head: HTTPRequestHead, body: Data) async -> HTTPResponse {
        // Ticket 03 replaces this with the held-open pairing prompt. Until then nothing pairs.
        Self.error(.pairingDenied, status: 403)
    }

    /// The answer to a request that could not be framed.
    nonisolated static func response(for error: HTTPFramingError) -> HTTPResponse {
        Self.error(.invalidRequest, status: 400)
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
