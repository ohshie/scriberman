import Foundation
import Network
import OSLog

/// Accepts HTTP connections on `127.0.0.1` and passes each request to the handler. It has no
/// routing or checks of its own: it frames bytes, enforces the connection limits and timeouts,
/// and writes back what the handler returns. One request per connection.
final class ExtensionAPIListener: @unchecked Sendable {
    struct Limits: Sendable {
        /// Open connections at once. One request per connection, so this is also how many
        /// requests can be in flight.
        var maximumConnections = 4
        /// From accepting a connection to the end of its head.
        var headDeadline: Duration = .seconds(10)
        /// The longest wait for the next piece of a body.
        var bodyGap: Duration = .seconds(30)
    }

    enum StartError: Error, Equatable {
        case alreadyStarted
        case failed(NWError)
        case cancelled
    }

    private let handler: any ExtensionAPIRequestHandling
    private let limits: Limits
    /// Guards every mutable property; also the queue all Network callbacks run on.
    private let queue = DispatchQueue(label: "Scriberman.ExtensionAPIListener")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ExtensionAPIConnection] = [:]
    private let logger = Logger(subsystem: "Scriberman", category: "ExtensionAPIListener")

    init(handler: any ExtensionAPIRequestHandling, limits: Limits = .init()) {
        self.handler = handler
        self.limits = limits
    }

    /// Binds `127.0.0.1:port` and returns the bound port (`0` asks the system for one).
    func start(port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard self.listener == nil else {
                    continuation.resume(throwing: StartError.alreadyStarted)
                    return
                }
                self.listener = listener
                let once = ResumeOnce(continuation)
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    switch state {
                    case .ready:
                        once.resume(with: .success(listener?.port?.rawValue ?? port))
                    case .failed(let error), .waiting(let error):
                        self?.logger.error("Extension API listener failed: \(error.debugDescription, privacy: .public)")
                        listener?.cancel()
                        self?.discard(listener)
                        once.resume(with: .failure(StartError.failed(error)))
                    case .cancelled:
                        self?.discard(listener)
                        once.resume(with: .failure(StartError.cancelled))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            }
        }
    }

    /// Stops listening and closes every open connection.
    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            let open = connections.values
            connections.removeAll()
            for connection in open {
                connection.close()
            }
        }
    }

    private func discard(_ listener: NWListener?) {
        guard let listener, self.listener === listener else { return }
        self.listener = nil
    }

    private func accept(_ nwConnection: NWConnection) {
        guard listener != nil, connections.count < limits.maximumConnections else {
            nwConnection.cancel()
            return
        }
        let connection = ExtensionAPIConnection(
            connection: nwConnection,
            queue: queue,
            handler: handler,
            limits: limits
        ) { [weak self] finished in
            self?.connections[ObjectIdentifier(finished)] = nil
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }
}

/// Resumes a continuation the first time only. Touched only on the listener's queue.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<UInt16, any Error>?

    init(_ continuation: CheckedContinuation<UInt16, any Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<UInt16, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// One accepted connection carrying one request. All state is touched only on `queue`.
private final class ExtensionAPIConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: any ExtensionAPIRequestHandling
    private let limits: ExtensionAPIListener.Limits
    private let onFinish: (ExtensionAPIConnection) -> Void

    private var framer = HTTPRequestFramer()
    private var head: HTTPRequestHead?
    private var body = Data()
    /// Where an import body goes instead of `body`. Discarded if the connection ends before it is
    /// handed to the handler.
    private var upload: ExtensionAPIStagedUpload?
    private var timer: DispatchWorkItem?
    private var isFinished = false
    /// The running `handle` call, cancelled when the connection ends before it answers.
    private var handleTask: Task<Void, Never>?

    private var peer: ExtensionAPIPeer {
        ExtensionAPIPeer(endpoint: connection.endpoint)
    }

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        handler: any ExtensionAPIRequestHandling,
        limits: ExtensionAPIListener.Limits,
        onFinish: @escaping (ExtensionAPIConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.limits = limits
        self.onFinish = onFinish
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        arm(limits.headDeadline)
        receive()
    }

    /// Closes at once, dropping anything unsent.
    func close() {
        connection.forceCancel()
        finish()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        timer?.cancel()
        handleTask?.cancel()
        handleTask = nil
        upload?.discard()
        upload = nil
        onFinish(self)
    }

    private func arm(_ duration: Duration) {
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.close()
        }
        timer = item
        let components = duration.components
        let nanoseconds = Int(components.seconds) * 1_000_000_000 + Int(components.attoseconds / 1_000_000_000)
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds), execute: item)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isFinished else { return }
            if let data, !data.isEmpty {
                guard self.consume(data) else { return }
            }
            if isComplete || error != nil {
                // The peer stopped sending before the request was whole; there is no one to answer.
                self.close()
                return
            }
            self.receive()
        }
    }

    /// Feeds bytes to the framer. Returns whether to keep reading.
    private func consume(_ data: Data) -> Bool {
        let events: [HTTPRequestFramer.Event]
        do {
            events = try framer.receive(data)
        } catch let error as HTTPFramingError {
            respond(ExtensionAPIHandler.response(for: error))
            return false
        } catch {
            close()
            return false
        }
        for event in events {
            switch event {
            case .head(let head):
                self.head = head
                timer?.cancel()
                admit(head, pending: Array(events.drop { $0 != .head(head) }.dropFirst()))
                return false
            case .body, .end:
                break
            }
        }
        return accept(events)
    }

    /// Asks the handler about the head, then resumes with the body bytes that arrived with it.
    private func admit(_ head: HTTPRequestHead, pending: [HTTPRequestFramer.Event]) {
        let handler = handler
        let peer = peer
        Task { [weak self] in
            let admission = await handler.admit(head, peer: peer)
            guard let self else {
                if case .admittedToFile(let upload) = admission { upload.discard() }
                return
            }
            self.queue.async {
                guard !self.isFinished else {
                    if case .admittedToFile(let upload) = admission { upload.discard() }
                    return
                }
                switch admission {
                case .refused(let response):
                    self.respond(response)
                case .admitted(let bodyLimit):
                    guard head.contentLength <= bodyLimit else {
                        self.respond(ExtensionAPIHandler.error(.payloadTooLarge, status: 413))
                        return
                    }
                    self.readBody(pending)
                case .admittedToFile(let upload):
                    self.upload = upload
                    self.readBody(pending)
                }
            }
        }
    }

    private func readBody(_ pending: [HTTPRequestFramer.Event]) {
        arm(limits.bodyGap)
        if accept(pending) {
            receive()
        }
    }

    /// Collects body events, into the staged upload when there is one. Returns whether to keep
    /// reading.
    private func accept(_ events: [HTTPRequestFramer.Event]) -> Bool {
        guard let head else { return true }
        for event in events {
            switch event {
            case .head:
                break
            case .body(let chunk):
                if let upload {
                    upload.write(chunk)
                } else {
                    body.append(chunk)
                }
                arm(limits.bodyGap)
            case .end:
                timer?.cancel()
                if let upload {
                    self.upload = nil
                    upload.finishWriting()
                    handleUpload(head, upload: upload)
                } else {
                    handle(head, body: body)
                }
                return false
            }
        }
        return true
    }

    private func handle(_ head: HTTPRequestHead, body: Data) {
        let handler = handler
        let peer = peer
        handleTask = Task { [weak self] in
            let response = await handler.handle(head, body: body, peer: peer)
            self?.queue.async {
                guard let self, !self.isFinished else { return }
                self.respond(response)
            }
        }
        watchForDisconnect()
    }

    private func handleUpload(_ head: HTTPRequestHead, upload: ExtensionAPIStagedUpload) {
        let handler = handler
        let peer = peer
        handleTask = Task { [weak self] in
            let response = await handler.handleUpload(head, upload: upload, peer: peer)
            self?.queue.async {
                guard let self, !self.isFinished else { return }
                self.respond(response)
            }
        }
        watchForDisconnect()
    }

    /// While the handler works, a close from the client (or any byte after the request) ends the
    /// connection, which cancels the handler's task.
    private func watchForDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, isComplete, error in
            guard let self, !self.isFinished else { return }
            if isComplete || error != nil || !(data?.isEmpty ?? true) {
                self.close()
            } else {
                self.watchForDisconnect()
            }
        }
    }

    private func respond(_ response: HTTPResponse) {
        timer?.cancel()
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.finish()
        })
    }
}
