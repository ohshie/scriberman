import Foundation
import Testing
@testable import Scriberman

struct HTTPFramingTests {
    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }

    @Test("A request split across many reads yields one head and the whole body")
    func partialReads() throws {
        let request = "POST /v1/pair HTTP/1.1\r\nHost: 127.0.0.1:47615\r\nContent-Length: 5\r\n\r\nhello"
        var framer = HTTPRequestFramer()
        var events: [HTTPRequestFramer.Event] = []
        for byte in bytes(request) {
            events += try framer.receive(Data([byte]))
        }

        let heads = events.compactMap { event -> HTTPRequestHead? in
            if case .head(let head) = event { return head }
            return nil
        }
        let body = events.reduce(into: Data()) { result, event in
            if case .body(let chunk) = event { result.append(chunk) }
        }
        #expect(heads.count == 1)
        #expect(heads.first?.method == "POST")
        #expect(heads.first?.path == "/v1/pair")
        #expect(heads.first?.contentLength == 5)
        #expect(body == bytes("hello"))
        #expect(events.last == .end)
    }

    private func frame(_ text: String) throws -> [HTTPRequestFramer.Event] {
        var framer = HTTPRequestFramer()
        return try framer.receive(bytes(text))
    }

    private func head(_ text: String) throws -> HTTPRequestHead? {
        try frame(text).compactMap { event -> HTTPRequestHead? in
            if case .head(let head) = event { return head }
            return nil
        }.first
    }

    @Test("Any Transfer-Encoding is rejected", arguments: ["chunked", "identity", "gzip, chunked"])
    func transferEncodingRejected(value: String) {
        #expect(throws: HTTPFramingError.transferEncodingNotSupported) {
            try frame("POST /v1/pair HTTP/1.1\r\nHost: 127.0.0.1:47615\r\nTransfer-Encoding: \(value)\r\n\r\n")
        }
    }

    @Test("Two different Content-Length values are rejected")
    func conflictingContentLength() {
        #expect(throws: HTTPFramingError.invalidContentLength) {
            try frame("POST /v1/pair HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabc")
        }
    }

    @Test("A repeated identical Content-Length is still rejected")
    func repeatedContentLength() {
        #expect(throws: HTTPFramingError.invalidContentLength) {
            try frame("POST /v1/pair HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc")
        }
    }

    @Test("A Content-Length that is not a plain decimal number is rejected", arguments: ["-1", "+3", "3 4", "abc", "", "0x10"])
    func malformedContentLength(value: String) {
        #expect(throws: HTTPFramingError.invalidContentLength) {
            try frame("POST /v1/pair HTTP/1.1\r\nHost: h\r\nContent-Length: \(value)\r\n\r\n")
        }
    }

    @Test("Without Content-Length the body is empty and the request ends with the head")
    func missingContentLength() throws {
        let events = try frame("GET /v1/status HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(events.count == 2)
        #expect(events.last == .end)
        let parsed = try #require(try head("GET /v1/status HTTP/1.1\r\nHost: h\r\n\r\n"))
        #expect(parsed.contentLength == 0)
    }

    @Test("Bytes after a request with no Content-Length are rejected")
    func bytesWithoutContentLength() {
        #expect(throws: HTTPFramingError.unexpectedBytesAfterRequest) {
            try frame("POST /v1/pair HTTP/1.1\r\nHost: h\r\n\r\nhello")
        }
    }

    @Test("Bytes beyond the declared body are rejected")
    func bytesBeyondBody() {
        #expect(throws: HTTPFramingError.unexpectedBytesAfterRequest) {
            try frame("POST /v1/pair HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\nhello")
        }
    }

    @Test("A header section over 16 KiB is rejected before its end arrives")
    func oversizedHeaderSection() {
        let filler = String(repeating: "a", count: 16 * 1024)
        #expect(throws: HTTPFramingError.headerSectionTooLarge) {
            try frame("GET /v1/status HTTP/1.1\r\nX-Filler: \(filler)\r\n")
        }
    }

    @Test("A header section of exactly 16 KiB is accepted")
    func headerSectionAtLimit() throws {
        let prefix = "GET /v1/status HTTP/1.1\r\nX-Filler: "
        let suffix = "\r\n\r\n"
        let filler = String(repeating: "a", count: 16 * 1024 - prefix.utf8.count - suffix.utf8.count)
        #expect(try head(prefix + filler + suffix) != nil)
    }

    @Test(
        "A malformed request line is rejected",
        arguments: [
            "GET /v1/status\r\n\r\n",
            "GET  /v1/status HTTP/1.1\r\n\r\n",
            "GET /v1/status HTTP/1.0\r\n\r\n",
            "GET /v1/status HTTP/2\r\n\r\n",
            "/v1/status HTTP/1.1\r\n\r\n",
            "GET /v1/status HTTP/1.1 extra\r\n\r\n",
            "G@T /v1/status HTTP/1.1\r\n\r\n",
            "GET /v1/st atus HTTP/1.1\r\n\r\n",
            "\r\n\r\n",
        ]
    )
    func malformedRequestLine(text: String) {
        #expect(throws: HTTPFramingError.malformedRequestLine) {
            try frame(text)
        }
    }

    @Test(
        "A header line without a name or colon is rejected",
        arguments: [
            "GET /v1/status HTTP/1.1\r\nHost 127.0.0.1\r\n\r\n",
            "GET /v1/status HTTP/1.1\r\n: value\r\n\r\n",
            "GET /v1/status HTTP/1.1\r\nHost : 127.0.0.1\r\n\r\n",
            "GET /v1/status HTTP/1.1\r\n folded\r\n\r\n",
        ]
    )
    func malformedHeaderLine(text: String) {
        #expect(throws: HTTPFramingError.malformedHeader) {
            try frame(text)
        }
    }

    @Test(
        "A target not in origin form is rejected",
        arguments: ["http://127.0.0.1:47615/v1/status", "127.0.0.1:47615", "*", "v1/status"]
    )
    func absoluteFormTarget(target: String) {
        #expect(throws: HTTPFramingError.targetNotOriginForm) {
            try frame("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:47615\r\n\r\n")
        }
    }

    @Test("Input that ends inside the head is premature")
    func endInsideHead() throws {
        var framer = HTTPRequestFramer()
        _ = try framer.receive(bytes("GET /v1/status HTTP/1.1\r\nHost: h\r\n"))
        #expect(throws: HTTPFramingError.prematureEndOfInput) {
            try framer.receiveEnd()
        }
    }

    @Test("Input that ends inside the body is premature")
    func endInsideBody() throws {
        var framer = HTTPRequestFramer()
        _ = try framer.receive(bytes("POST /v1/pair HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhel"))
        #expect(throws: HTTPFramingError.prematureEndOfInput) {
            try framer.receiveEnd()
        }
    }

    @Test("Input that ends after a complete request is fine")
    func endAfterRequest() throws {
        var framer = HTTPRequestFramer()
        _ = try framer.receive(bytes("GET /v1/status HTTP/1.1\r\nHost: h\r\n\r\n"))
        try framer.receiveEnd()
    }

    @Test("Duplicate headers are kept in arrival order with their original case")
    func duplicateHeadersPreserved() throws {
        let parsed = try #require(try head("GET /v1/status HTTP/1.1\r\nHost: a\r\nhost: b\r\nOrigin: null\r\n\r\n"))
        #expect(parsed.values(for: "HOST") == ["a", "b"])
        #expect(parsed.headers.map(\.name) == ["Host", "host", "Origin"])
    }

    @Test("Header values lose surrounding whitespace only")
    func headerValueWhitespace() throws {
        let parsed = try #require(try head("GET /v1/status HTTP/1.1\r\nX-Name:  a  b \t\r\n\r\n"))
        #expect(parsed.values(for: "x-name") == ["a  b"])
    }

    @Test("The path drops the query")
    func pathDropsQuery() throws {
        let parsed = try #require(try head("GET /v1/sessions?q=a%20b&limit=5 HTTP/1.1\r\nHost: h\r\n\r\n"))
        #expect(parsed.path == "/v1/sessions")
        #expect(parsed.target == "/v1/sessions?q=a%20b&limit=5")
    }
}

struct HTTPResponseTests {
    @Test("A response is written with its status, length and Connection: close")
    func serialization() {
        let response = HTTPResponse(status: 404, headers: [.init(name: "Content-Type", value: "application/json")], body: Data("{}".utf8))
        let text = String(decoding: response.serialized(), as: UTF8.self)
        #expect(text == "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
    }
}
