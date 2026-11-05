import Foundation
import Network
import Testing
@testable import Scriberman

private struct EchoHandler: ExtensionAPIRequestHandling {
    func admit(_ head: HTTPRequestHead, peer: ExtensionAPIPeer) async -> ExtensionAPIAdmission { .admitted(bodyLimit: 1024) }
    func handle(_ head: HTTPRequestHead, body: Data, peer: ExtensionAPIPeer) async -> HTTPResponse { HTTPResponse(status: 200) }
    func apiDidStop() async {}
}

/// Counts `apiDidStop` calls.
private final class StopCountingHandler: ExtensionAPIRequestHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var _stops = 0
    var stops: Int { lock.withLock { _stops } }

    func admit(_ head: HTTPRequestHead, peer: ExtensionAPIPeer) async -> ExtensionAPIAdmission { .admitted(bodyLimit: 1024) }
    func handle(_ head: HTTPRequestHead, body: Data, peer: ExtensionAPIPeer) async -> HTTPResponse { HTTPResponse(status: 200) }
    func apiDidStop() async { lock.withLock { _stops += 1 } }
}

@MainActor
@Suite(.serialized)
struct ExtensionAPIServiceTests {
    private func makeSettings() -> ExtensionAPISettings {
        ExtensionAPISettings(userDefaults: UserDefaults(suiteName: "ExtensionAPIServiceTests-\(UUID().uuidString)")!)
    }

    private func makeService(_ settings: ExtensionAPISettings) -> ExtensionAPIService {
        ExtensionAPIService(settings: settings, handler: EchoHandler())
    }

    /// A port nothing listens on right now.
    private func freePort() async throws -> Int {
        let probe = ExtensionAPIListener(handler: EchoHandler())
        let port = try await probe.start(port: 0)
        probe.stop()
        return Int(port)
    }

    /// Holds a port so the service cannot bind it. Stop it when done.
    private func occupiedPort() async throws -> (Int, ExtensionAPIListener) {
        let holder = ExtensionAPIListener(handler: EchoHandler())
        return (Int(try await holder.start(port: 0)), holder)
    }

    private func isAccepting(_ port: Int) -> Bool {
        guard let client = try? LoopbackClient(port: UInt16(port)) else { return false }
        return client.read(timeout: 0.2) == .timedOut
    }

    @Test("With the API off nothing listens")
    func offByDefault() async throws {
        let settings = makeSettings()
        let service = makeService(settings)
        await service.apply()
        #expect(service.state == .stopped)
        #expect(!isAccepting(settings.port))
    }

    @Test("Turning the API on listens on the configured port")
    func enabledListens() async throws {
        let settings = makeSettings()
        try settings.setPort(try await freePort())
        settings.isEnabled = true
        let service = makeService(settings)
        await service.apply()
        defer { settings.isEnabled = false; service.stopNow() }
        #expect(service.state == .listening(port: settings.port))
        #expect(isAccepting(settings.port))
    }

    @Test("A taken port leaves the API stopped with the failure readable")
    func bindFailure() async throws {
        let (port, holder) = try await occupiedPort()
        defer { holder.stop() }
        let settings = makeSettings()
        try settings.setPort(port)
        settings.isEnabled = true
        let service = makeService(settings)
        await service.apply()
        guard case .failed(let failure) = service.state else {
            Issue.record("state is \(service.state)")
            return
        }
        #expect(failure.port == port)
        #expect(failure.error == .posix(.EADDRINUSE))
    }

    @Test("Changing the port rebinds and frees the old one")
    func rebind() async throws {
        let settings = makeSettings()
        let old = try await freePort()
        try settings.setPort(old)
        settings.isEnabled = true
        let service = makeService(settings)
        await service.apply()
        defer { service.stopNow() }

        let new = try await freePort()
        try settings.setPort(new)
        await service.apply()
        #expect(service.state == .listening(port: new))
        #expect(isAccepting(new))
        #expect(!isAccepting(old))
    }

    @Test("A failed rebind leaves the API stopped, the old port closed and the failure readable")
    func failedRebind() async throws {
        let settings = makeSettings()
        let old = try await freePort()
        try settings.setPort(old)
        settings.isEnabled = true
        let service = makeService(settings)
        await service.apply()
        defer { service.stopNow() }

        let (taken, holder) = try await occupiedPort()
        defer { holder.stop() }
        try settings.setPort(taken)
        await service.apply()
        guard case .failed(let failure) = service.state else {
            Issue.record("state is \(service.state)")
            return
        }
        #expect(failure.port == taken)
        #expect(!isAccepting(old))
    }

    @Test("Turning the API off closes open connections")
    func disableClosesConnections() async throws {
        let settings = makeSettings()
        try settings.setPort(try await freePort())
        settings.isEnabled = true
        let service = makeService(settings)
        await service.apply()
        let client = try LoopbackClient(port: UInt16(settings.port))
        try await Task.sleep(for: .milliseconds(200))

        settings.isEnabled = false
        await service.apply()
        #expect(service.state == .stopped)
        #expect(client.read(timeout: 3) == .closed)
        #expect(!isAccepting(settings.port))
    }

    @Test("After start, settings changes are applied without being asked")
    func followsSettings() async throws {
        let settings = makeSettings()
        try settings.setPort(try await freePort())
        let service = makeService(settings)
        service.start()
        defer { service.stopNow() }

        settings.isEnabled = true
        try await waitFor { service.state == .listening(port: settings.port) }

        settings.isEnabled = false
        try await waitFor { service.state == .stopped }
        #expect(!isAccepting(settings.port))
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Turning the API off tells the handler, so a held pairing ends")
    func turningOffTellsHandler() async throws {
        let settings = makeSettings()
        try settings.setPort(try await freePort())
        settings.isEnabled = true
        let handler = StopCountingHandler()
        let service = ExtensionAPIService(settings: settings, handler: handler)
        await service.apply()
        #expect(handler.stops == 0)

        settings.isEnabled = false
        await service.apply()
        #expect(handler.stops == 1)
        #expect(service.state == .stopped)
    }
}
