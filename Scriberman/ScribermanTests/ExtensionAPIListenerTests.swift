import Darwin
import Foundation
import Testing
@testable import Scriberman

/// A blocking TCP client over BSD sockets, so the test side shares no code with the listener.
final class LoopbackClient {
    enum ReadResult: Equatable {
        case data(Data)
        case closed
        case timedOut
    }

    private let fd: Int32

    init(port: UInt16, host: String = "127.0.0.1") throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        // Writing after the listener closed must fail the write, not kill the test process.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    deinit {
        close(fd)
    }

    func send(_ text: String) {
        _ = Array(text.utf8).withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }

    /// Waits up to `timeout` for bytes or for the peer to close.
    func read(timeout: TimeInterval) -> ReadResult {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = recv(fd, &buffer, buffer.count, 0)
        if count > 0 { return .data(Data(buffer[0..<count])) }
        if count == 0 { return .closed }
        return errno == EAGAIN || errno == EWOULDBLOCK ? .timedOut : .closed
    }

    /// Everything the peer sends until it closes, or nil if it stays open past `timeout`.
    func readToEnd(timeout: TimeInterval) -> Data? {
        var all = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch read(timeout: max(0.05, deadline.timeIntervalSinceNow)) {
            case .data(let data): all.append(data)
            case .closed: return all
            case .timedOut: return nil
            }
        }
        return nil
    }
}

/// The local addresses this process has TCP sockets listening on at `port`, read from the kernel.
func listeningAddresses(port: UInt16) -> [String] {
    let pid = getpid()
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
    let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
    var addresses: [String] = []
    for fdInfo in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fdInfo.proc_fdtype == PROX_FDTYPE_SOCKET {
        var info = socket_fdinfo()
        let got = proc_pidfdinfo(pid, fdInfo.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
        guard got == MemoryLayout<socket_fdinfo>.size, info.psi.soi_kind == SOCKINFO_TCP else { continue }
        let tcp = info.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
        let ini = tcp.tcpsi_ini
        guard UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)) == port else { continue }
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var addr = ini.insi_laddr.ina_46.i46a_addr4
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &text, socklen_t(text.count))
            addresses.append(String(cString: text))
        } else {
            var addr = ini.insi_laddr.ina_6
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count))
            addresses.append(String(cString: text))
        }
    }
    return addresses
}

private struct StubHandler: ExtensionAPIRequestHandling {
    func admit(_ head: HTTPRequestHead, peer: ExtensionAPIPeer) async -> ExtensionAPIAdmission {
        head.path == "/refuse" ? .refused(HTTPResponse(status: 403)) : .admitted(bodyLimit: 1024)
    }

    func handle(_ head: HTTPRequestHead, body: Data, peer: ExtensionAPIPeer) async -> HTTPResponse {
        HTTPResponse(status: 200, body: body)
    }
    func apiDidStop() async {}
}

/// Holds `handle` open until its task is cancelled, and records what it saw.
private final class HoldingHandler: ExtensionAPIRequestHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var _handleStarted = false
    private var _handleCancelled = false
    private var _admitPeer: ExtensionAPIPeer?

    var handleStarted: Bool { lock.withLock { _handleStarted } }
    var handleCancelled: Bool { lock.withLock { _handleCancelled } }
    var admitPeer: ExtensionAPIPeer? { lock.withLock { _admitPeer } }

    func admit(_ head: HTTPRequestHead, peer: ExtensionAPIPeer) async -> ExtensionAPIAdmission {
        lock.withLock { _admitPeer = peer }
        return .admitted(bodyLimit: 1024)
    }

    func handle(_ head: HTTPRequestHead, body: Data, peer: ExtensionAPIPeer) async -> HTTPResponse {
        lock.withLock { _handleStarted = true }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        lock.withLock { _handleCancelled = true }
        return HTTPResponse(status: 200)
    }

    func apiDidStop() async {}
}

/// Polls `condition` for up to `seconds`.
private func eventually(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite(.serialized)
struct ExtensionAPIListenerTests {
    private func makeListener(
        headDeadline: Duration = .seconds(10),
        bodyGap: Duration = .seconds(30)
    ) -> ExtensionAPIListener {
        ExtensionAPIListener(
            handler: StubHandler(),
            limits: .init(maximumConnections: 4, headDeadline: headDeadline, bodyGap: bodyGap)
        )
    }

    private func text(_ data: Data?) -> String {
        data.map { String(decoding: $0, as: UTF8.self) } ?? "<still open>"
    }

    @Test("The listener binds 127.0.0.1 and nothing else")
    func boundAddress() async throws {
        let listener = makeListener()
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        #expect(listeningAddresses(port: port) == ["127.0.0.1"])
    }

    @Test("A request gets its response and the connection is closed")
    func roundTrip() async throws {
        let listener = makeListener()
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let client = try LoopbackClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhel")
        client.send("lo")
        let response = text(client.readToEnd(timeout: 5))
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.hasSuffix("\r\n\r\nhello"))
    }

    @Test("A refused request is answered without its body being read")
    func refusedRequest() async throws {
        let listener = makeListener()
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let client = try LoopbackClient(port: port)
        client.send("POST /refuse HTTP/1.1\r\nHost: h\r\nContent-Length: 100\r\n\r\n")
        #expect(text(client.readToEnd(timeout: 5)).hasPrefix("HTTP/1.1 403 "))
    }

    @Test("A declared body over the admitted limit is refused")
    func bodyOverAdmittedLimit() async throws {
        let listener = makeListener()
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let client = try LoopbackClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 1025\r\n\r\n")
        #expect(text(client.readToEnd(timeout: 5)).hasPrefix("HTTP/1.1 413 "))
    }

    @Test("A request that cannot be framed is answered 400")
    func framingError() async throws {
        let listener = makeListener()
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let client = try LoopbackClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n")
        #expect(text(client.readToEnd(timeout: 5)).hasPrefix("HTTP/1.1 400 "))
    }

    @Test("A fifth open connection is closed while four stay open")
    func fifthConnectionRefused() async throws {
        let listener = makeListener()
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let open = try (0..<4).map { _ in try LoopbackClient(port: port) }
        try await Task.sleep(for: .milliseconds(200))
        let fifth = try LoopbackClient(port: port)
        #expect(fifth.read(timeout: 3) == .closed)
        for client in open {
            #expect(client.read(timeout: 0.1) == .timedOut)
        }
    }

    @Test("A slot frees up once a connection ends")
    func slotFreedAfterClose() async throws {
        let listener = makeListener()
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        var open = try (0..<4).map { _ in try LoopbackClient(port: port) }
        open.removeLast()
        try await Task.sleep(for: .milliseconds(300))
        let next = try LoopbackClient(port: port)
        #expect(next.read(timeout: 0.3) == .timedOut)
        _ = open
    }

    @Test("A connection whose head does not arrive in time is closed")
    func stalledHeadClosed() async throws {
        let listener = makeListener(headDeadline: .milliseconds(500))
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let client = try LoopbackClient(port: port)
        client.send("GET /echo HTTP/1.1\r\n")
        let started = Date()
        #expect(client.readToEnd(timeout: 5) != nil)
        #expect(Date().timeIntervalSince(started) > 0.3)
    }

    @Test("A head trickled in byte by byte still meets the deadline as a whole")
    func headDeadlineIsTotal() async throws {
        let listener = makeListener(headDeadline: .milliseconds(500))
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let client = try LoopbackClient(port: port)
        for _ in 0..<10 {
            client.send("X")
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(client.read(timeout: 2) != .timedOut)
    }

    @Test("A body that stops arriving is closed after the gap")
    func stalledBodyClosed() async throws {
        let listener = makeListener(bodyGap: .milliseconds(500))
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let client = try LoopbackClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 10\r\n\r\nabc")
        let started = Date()
        #expect(client.readToEnd(timeout: 5) != nil)
        #expect(Date().timeIntervalSince(started) > 0.3)
    }

    @Test("A body that keeps arriving is not cut off by the gap")
    func steadyBodyKept() async throws {
        let listener = makeListener(bodyGap: .milliseconds(500))
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let client = try LoopbackClient(port: port)
        client.send("POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\n")
        for byte in ["a", "b", "c", "d"] {
            try await Task.sleep(for: .milliseconds(300))
            client.send(byte)
        }
        #expect(text(client.readToEnd(timeout: 5)).hasSuffix("abcd"))
    }

    @Test("A second listener on a taken port fails to start")
    func portInUse() async throws {
        let first = makeListener()
        let port = try await first.start(port: 0)
        defer { first.stop() }
        let second = makeListener()
        await #expect(throws: (any Error).self) {
            _ = try await second.start(port: port)
        }
    }

    @Test("Stopping closes open connections and the port")
    func stopClosesEverything() async throws {
        let listener = makeListener()
        let port = try await listener.start(port: 0)
        let client = try LoopbackClient(port: port)
        try await Task.sleep(for: .milliseconds(200))
        listener.stop()
        #expect(client.read(timeout: 3) == .closed)
        try await Task.sleep(for: .milliseconds(200))
        #expect(throws: (any Error).self) {
            _ = try LoopbackClient(port: port)
        }
    }

    @Test("A client that disconnects while its request is handled cancels the handler's task")
    func disconnectCancelsHandle() async throws {
        let handler = HoldingHandler()
        let listener = ExtensionAPIListener(handler: handler)
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        var client: LoopbackClient? = try LoopbackClient(port: port)
        client?.send("POST /pair HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\n{}")
        #expect(await eventually { handler.handleStarted })
        #expect(!handler.handleCancelled)

        client = nil
        #expect(await eventually { handler.handleCancelled })
    }

    @Test("Stopping the listener cancels a request being handled")
    func stopCancelsHandle() async throws {
        let handler = HoldingHandler()
        let listener = ExtensionAPIListener(handler: handler)
        let port = try await listener.start(port: 0)
        let client = try LoopbackClient(port: port)
        client.send("POST /pair HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\n{}")
        #expect(await eventually { handler.handleStarted })

        listener.stop()
        #expect(await eventually { handler.handleCancelled })
    }

    @Test("The handler receives the connection's remote endpoint as the peer")
    func peerPassed() async throws {
        let handler = HoldingHandler()
        let listener = ExtensionAPIListener(handler: handler)
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let client = try LoopbackClient(port: port)
        client.send("POST /pair HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\n{}")
        #expect(await eventually { handler.admitPeer != nil })
        guard case .hostPort(let host, _) = handler.admitPeer?.endpoint else {
            Issue.record("peer endpoint is \(String(describing: handler.admitPeer?.endpoint))")
            return
        }
        #expect("\(host)" == "127.0.0.1")
    }
}
