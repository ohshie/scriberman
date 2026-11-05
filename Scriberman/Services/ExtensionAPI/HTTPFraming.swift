import Foundation

/// The request line and header section of one HTTP/1.1 request.
struct HTTPRequestHead: Equatable, Sendable {
    struct Header: Equatable, Sendable {
        let name: String
        let value: String
    }

    let method: String
    /// The request target as sent, in origin form (`/path?query`).
    let target: String
    /// Every header line in arrival order, duplicates kept, so checks can reject them.
    let headers: [Header]
    /// The declared body length; zero when the request has no `Content-Length`.
    let contentLength: Int

    /// The target without its query.
    var path: String {
        String(target.prefix { $0 != "?" })
    }

    /// Every value sent under `name`, compared without regard to case.
    func values(for name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }
}

/// Why a request could not be framed. Every case is answered `400` and the connection closed.
enum HTTPFramingError: Error, Equatable, Sendable {
    case malformedRequestLine
    case malformedHeader
    case targetNotOriginForm
    case transferEncodingNotSupported
    case invalidContentLength
    case headerSectionTooLarge
    case unexpectedBytesAfterRequest
    case prematureEndOfInput
}

/// Turns the bytes of one request into its head, its body and its end. It has no socket: the
/// caller feeds it what it reads. Rules: HTTP/1.1 only, one request per connection, body length
/// from `Content-Length` alone (absent means empty), any `Transfer-Encoding` rejected, origin-form
/// targets only, and a header section of at most 16 KiB.
struct HTTPRequestFramer {
    enum Event: Equatable, Sendable {
        case head(HTTPRequestHead)
        case body(Data)
        case end
    }

    /// The most bytes the request line, header lines and the blank line after them may take.
    static let maximumHeaderSectionBytes = 16 * 1024

    private enum State {
        case head
        case body(remaining: Int)
        case done
    }

    private var state = State.head
    private var buffer = Data()

    var isComplete: Bool {
        if case .done = state { return true }
        return false
    }

    mutating func receive(_ data: Data) throws -> [Event] {
        switch state {
        case .head:
            buffer.append(data)
            guard let range = buffer.firstRange(of: Self.headTerminator) else {
                if buffer.count >= Self.maximumHeaderSectionBytes {
                    throw HTTPFramingError.headerSectionTooLarge
                }
                return []
            }
            if range.upperBound - buffer.startIndex > Self.maximumHeaderSectionBytes {
                throw HTTPFramingError.headerSectionTooLarge
            }
            let head = try Self.parseHead(Data(buffer[buffer.startIndex..<range.lowerBound]))
            let rest = Data(buffer[range.upperBound...])
            buffer = Data()
            state = .body(remaining: head.contentLength)
            return [.head(head)] + (try receiveBody(rest))
        case .body:
            return try receiveBody(data)
        case .done:
            if !data.isEmpty {
                throw HTTPFramingError.unexpectedBytesAfterRequest
            }
            return []
        }
    }

    /// The peer closed its side. Throws when that cuts the request short.
    mutating func receiveEnd() throws {
        guard isComplete else {
            throw HTTPFramingError.prematureEndOfInput
        }
    }

    private mutating func receiveBody(_ data: Data) throws -> [Event] {
        guard case .body(let remaining) = state else { return [] }
        if data.count > remaining {
            throw HTTPFramingError.unexpectedBytesAfterRequest
        }
        var events: [Event] = []
        if !data.isEmpty {
            events.append(.body(data))
        }
        let left = remaining - data.count
        if left == 0 {
            state = .done
            events.append(.end)
        } else {
            state = .body(remaining: left)
        }
        return events
    }

    private static let headTerminator = Data("\r\n\r\n".utf8)

    /// RFC 9110 `tchar`, the characters a method or header name may use.
    private static let tokenCharacters = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    private static func isToken(_ text: some StringProtocol) -> Bool {
        !text.isEmpty && text.allSatisfy { tokenCharacters.contains($0) }
    }

    private static func parseHead(_ bytes: Data) throws -> HTTPRequestHead {
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw HTTPFramingError.malformedHeader
        }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, isToken(parts[0]), !parts[1].isEmpty, parts[2] == "HTTP/1.1" else {
            throw HTTPFramingError.malformedRequestLine
        }
        let target = String(parts[1])
        guard target.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "\t" }) else {
            throw HTTPFramingError.malformedRequestLine
        }
        guard target.hasPrefix("/") else {
            throw HTTPFramingError.targetNotOriginForm
        }

        var headers: [HTTPRequestHead.Header] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), isToken(line[..<colon]) else {
                throw HTTPFramingError.malformedHeader
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            headers.append(.init(name: String(line[..<colon]), value: value))
        }
        let head = HTTPRequestHead(method: String(parts[0]), target: target, headers: headers, contentLength: 0)

        if !head.values(for: "Transfer-Encoding").isEmpty {
            throw HTTPFramingError.transferEncodingNotSupported
        }
        let lengths = head.values(for: "Content-Length")
        guard lengths.count <= 1 else {
            throw HTTPFramingError.invalidContentLength
        }
        guard let declared = lengths.first else {
            return head
        }
        guard !declared.isEmpty, declared.count <= 18, declared.allSatisfy(\.isASCIIDigit), let length = Int(declared) else {
            throw HTTPFramingError.invalidContentLength
        }
        return HTTPRequestHead(method: head.method, target: target, headers: headers, contentLength: length)
    }
}

/// One response. It always closes the connection, since each connection carries one request.
struct HTTPResponse: Equatable, Sendable {
    let status: Int
    let headers: [HTTPRequestHead.Header]
    let body: Data

    init(status: Int, headers: [HTTPRequestHead.Header] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    func serialized() -> Data {
        var text = "HTTP/1.1 \(status) \(Self.reasonPhrase(for: status))\r\n"
        for header in headers {
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(text.utf8) + body
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        case 507: "Insufficient Storage"
        default: "Status"
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
