import Foundation
import Network
import Security
import Testing
@testable import Scriberman

// MARK: - Fakes

/// A fake operating system: which process owns each client socket, and each process's
/// signature. Processes carry a version, as audit tokens do, so a reused PID is a new process.
final class FakeCallerSystem: CallerProcessInspecting, @unchecked Sendable {
    private struct Process {
        var version: UInt32
        var signature: CallerSignature
    }

    private let lock = NSLock()
    private var owners: [UInt16: Int32] = [:]
    private var processes: [Int32: Process] = [:]
    private var nextVersion: UInt32 = 1
    private var _tableFailure: CallerRefusal?
    private var _afterAuditToken: (@Sendable (FakeCallerSystem, Int32) -> Void)?

    /// When set, reading the connection table fails with this refusal.
    var tableFailure: CallerRefusal? {
        get { lock.withLock { _tableFailure } }
        set { lock.withLock { _tableFailure = newValue } }
    }

    /// Runs once after an audit token is taken, before the table is read again.
    var afterAuditToken: (@Sendable (FakeCallerSystem, Int32) -> Void)? {
        get { lock.withLock { _afterAuditToken } }
        set { lock.withLock { _afterAuditToken = newValue } }
    }

    func launch(_ pid: Int32, _ signature: CallerSignature) {
        lock.withLock {
            processes[pid] = Process(version: nextVersion, signature: signature)
            nextVersion += 1
        }
    }

    func exit(_ pid: Int32) {
        lock.withLock { _ = processes.removeValue(forKey: pid) }
    }

    /// Records `pid` as the last process to use the socket on `clientPort`.
    func connect(clientPort: UInt16, pid: Int32) {
        lock.withLock { owners[clientPort] = pid }
    }

    func connectionOwner(clientPort: UInt16, serverPort: UInt16) throws(CallerRefusal) -> TCPConnectionOwner {
        let (failure, pid) = lock.withLock { (_tableFailure, owners[clientPort]) }
        if let failure { throw failure }
        guard let pid else { throw .connectionNotFound }
        return TCPConnectionOwner(pid: pid, uid: 501)
    }

    func auditToken(for pid: Int32) throws(CallerRefusal) -> CallerAuditToken {
        let process = lock.withLock { processes[pid] }
        guard let process else { throw .auditTokenUnavailable }
        let token = CallerAuditToken(pid: pid, pidVersion: process.version)
        let hook = lock.withLock {
            defer { _afterAuditToken = nil }
            return _afterAuditToken
        }
        hook?(self, pid)
        return token
    }

    private func process(for token: CallerAuditToken) throws(CallerRefusal) -> Process {
        let process = lock.withLock { processes[token.pid] }
        guard let process, process.version == token.pidVersion else {
            throw .codeUnavailable(-67065)
        }
        return process
    }

    func signature(of token: CallerAuditToken) throws(CallerRefusal) -> CallerSignature {
        try process(for: token).signature
    }

    func validity(of token: CallerAuditToken, against requirement: String) throws(CallerRefusal) -> OSStatus {
        let signature = try process(for: token).signature
        guard signature.validity == errSecSuccess else { return signature.validity }
        return signature.designatedRequirement == requirement ? errSecSuccess : -67050
    }
}

/// Collects the refusals a verifier reports.
final class RefusalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [CallerRefusal] = []
    var entries: [CallerRefusal] { lock.withLock { _entries } }
    func record(_ refusal: CallerRefusal) { lock.withLock { _entries.append(refusal) } }
}

enum Signatures {
    static let tinycastRequirement =
        "anchor apple generic and identifier \"com.tinycast.app\" and certificate leaf[subject.OU] = \"J656U8XZ93\""
    static let tinycast = CallerSignature(
        validity: errSecSuccess,
        isAdHoc: false,
        designatedRequirement: tinycastRequirement,
        identifier: "com.tinycast.app",
        teamIdentifier: "J656U8XZ93"
    )
    /// Tinycast after a change of signing team.
    static let tinycastNewTeam = CallerSignature(
        validity: errSecSuccess,
        isAdHoc: false,
        designatedRequirement:
            "anchor apple generic and identifier \"com.tinycast.app\" and certificate leaf[subject.OU] = \"NEWTEAM123\"",
        identifier: "com.tinycast.app",
        teamIdentifier: "NEWTEAM123"
    )
    static let curl = CallerSignature(
        validity: errSecSuccess,
        isAdHoc: false,
        designatedRequirement: "identifier \"com.apple.curl\" and anchor apple",
        identifier: "com.apple.curl",
        teamIdentifier: nil
    )
    static let shell = CallerSignature(
        validity: errSecSuccess,
        isAdHoc: false,
        designatedRequirement: "identifier \"com.apple.sh\" and anchor apple",
        identifier: "com.apple.sh",
        teamIdentifier: nil
    )
    static let adHoc = CallerSignature(
        validity: errSecSuccess,
        isAdHoc: true,
        designatedRequirement: "cdhash H\"0123456789abcdef0123456789abcdef01234567\"",
        identifier: "com.tinycast.app",
        teamIdentifier: nil
    )
    static let unsigned = CallerSignature(
        validity: -67062,
        isAdHoc: false,
        designatedRequirement: nil,
        identifier: nil,
        teamIdentifier: nil
    )
    /// Code on disk no longer matches the running process (updated, not relaunched).
    static let changedOnDisk = CallerSignature(
        validity: -67034,
        isAdHoc: false,
        designatedRequirement: tinycastRequirement,
        identifier: "com.tinycast.app",
        teamIdentifier: "J656U8XZ93"
    )
}

private let serverPort: UInt16 = 47615
private let clientPort: UInt16 = 50001

private func peer(clientPort: UInt16 = clientPort) -> ExtensionAPIPeer {
    ExtensionAPIPeer(
        endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: clientPort)!),
        localEndpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: serverPort)!)
    )
}

private struct VerifierFixture {
    let system = FakeCallerSystem()
    let log = RefusalLog()
    var verifier: CodeSigningCallerVerifier {
        CodeSigningCallerVerifier(inspector: system, onRefusal: { [log] in log.record($0) })
    }
}

// MARK: - Verifier decisions

struct CodeSigningCallerVerifierTests {
    @Test("Pairing a validly signed caller records its designated requirement, identifier and team")
    func pairingRecordsIdentity() async throws {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.tinycast)
        fixture.system.connect(clientPort: clientPort, pid: 100)
        let identity = try #require(await fixture.verifier.identityForPairing(peer()))
        #expect(identity.designatedRequirement == Signatures.tinycastRequirement)
        #expect(identity.signingIdentifier == "com.tinycast.app")
        #expect(identity.teamIdentifier == "J656U8XZ93")
        #expect(fixture.log.entries.isEmpty)
    }

    @Test("An ad hoc signed caller can't pair")
    func adHocCannotPair() async {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.adHoc)
        fixture.system.connect(clientPort: clientPort, pid: 100)
        #expect(await fixture.verifier.identityForPairing(peer()) == nil)
        #expect(fixture.log.entries == [.adHocSignature])
    }

    @Test("An unsigned caller can't pair")
    func unsignedCannotPair() async {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.unsigned)
        fixture.system.connect(clientPort: clientPort, pid: 100)
        #expect(await fixture.verifier.identityForPairing(peer()) == nil)
        #expect(fixture.log.entries == [.invalidSignature(-67062)])
    }

    @Test("A caller whose code on disk no longer matches can't pair")
    func changedOnDiskCannotPair() async {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.changedOnDisk)
        fixture.system.connect(clientPort: clientPort, pid: 100)
        #expect(await fixture.verifier.identityForPairing(peer()) == nil)
        #expect(fixture.log.entries == [.invalidSignature(-67034)])
    }

    @Test("A request from the paired, signed process passes")
    func pairedProcessPasses() async throws {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.tinycast)
        fixture.system.connect(clientPort: clientPort, pid: 100)
        let identity = try #require(await fixture.verifier.identityForPairing(peer()))
        fixture.system.connect(clientPort: 50002, pid: 100)
        #expect(await fixture.verifier.verify(peer(clientPort: 50002), matches: identity))
    }

    @Test("A request from another process is refused", arguments: [Signatures.curl, Signatures.shell, Signatures.tinycastNewTeam, Signatures.adHoc])
    func otherProcessRefused(_ signature: CallerSignature) async {
        let fixture = VerifierFixture()
        fixture.system.launch(200, signature)
        fixture.system.connect(clientPort: clientPort, pid: 200)
        let identity = ExtensionAPICallerIdentity(designatedRequirement: Signatures.tinycastRequirement)
        #expect(await fixture.verifier.verify(peer(), matches: identity) == false)
        #expect(fixture.log.entries == [.requirementNotSatisfied(-67050)])
    }

    @Test("Tinycast updated on disk but not relaunched is refused")
    func changedOnDiskRefused() async {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.changedOnDisk)
        fixture.system.connect(clientPort: clientPort, pid: 100)
        let identity = ExtensionAPICallerIdentity(designatedRequirement: Signatures.tinycastRequirement)
        #expect(await fixture.verifier.verify(peer(), matches: identity) == false)
        #expect(fixture.log.entries == [.requirementNotSatisfied(-67034)])
    }

    @Test("A child of the paired process is refused: its parent is not consulted")
    func childRefused() async {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.tinycast)
        fixture.system.launch(101, Signatures.curl) // started by 100
        fixture.system.connect(clientPort: clientPort, pid: 101)
        let identity = ExtensionAPICallerIdentity(designatedRequirement: Signatures.tinycastRequirement)
        #expect(await fixture.verifier.verify(peer(), matches: identity) == false)
    }

    @Test("A process that exited before its audit token was taken is refused")
    func exitedBeforeToken() async {
        let fixture = VerifierFixture()
        fixture.system.connect(clientPort: clientPort, pid: 100) // record keeps the dead PID
        let identity = ExtensionAPICallerIdentity(designatedRequirement: Signatures.tinycastRequirement)
        #expect(await fixture.verifier.verify(peer(), matches: identity) == false)
        #expect(await fixture.verifier.identityForPairing(peer()) == nil)
        #expect(fixture.log.entries == [.auditTokenUnavailable, .auditTokenUnavailable])
    }

    @Test("A process that exits after its token was taken is refused, even if its PID is reused by a signed process")
    func exitedAfterTokenPIDReused() async {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.curl)
        fixture.system.connect(clientPort: clientPort, pid: 100)
        fixture.system.afterAuditToken = { system, pid in
            system.exit(pid)
            system.launch(pid, Signatures.tinycast)
        }
        let identity = ExtensionAPICallerIdentity(designatedRequirement: Signatures.tinycastRequirement)
        #expect(await fixture.verifier.verify(peer(), matches: identity) == false)
        #expect(fixture.log.entries == [.codeUnavailable(-67065)])
    }

    @Test("A socket handed to another process after the token was taken is refused")
    func socketHandedOff() async {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.tinycast)
        fixture.system.launch(300, Signatures.tinycast)
        fixture.system.connect(clientPort: clientPort, pid: 100)
        fixture.system.afterAuditToken = { system, _ in
            system.connect(clientPort: clientPort, pid: 300)
        }
        let identity = ExtensionAPICallerIdentity(designatedRequirement: Signatures.tinycastRequirement)
        #expect(await fixture.verifier.verify(peer(), matches: identity) == false)
        #expect(fixture.log.entries == [.ownerChanged])
    }

    @Test("A connection that vanishes from the table after the token was taken is refused")
    func recordGoneOnRecheck() async {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.tinycast)
        fixture.system.connect(clientPort: clientPort, pid: 100)
        fixture.system.afterAuditToken = { system, _ in
            system.tableFailure = .connectionNotFound
        }
        #expect(await fixture.verifier.identityForPairing(peer()) == nil)
        #expect(fixture.log.entries == [.connectionNotFound])
    }

    @Test(
        "A missing record, an unexpected layout or an unreadable table fails closed and is logged",
        arguments: [
            CallerRefusal.connectionNotFound,
            .connectionAmbiguous,
            .unexpectedTableLayout,
            .connectionTableUnreadable(1),
        ]
    )
    func tableFailuresFailClosed(_ failure: CallerRefusal) async {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.tinycast)
        fixture.system.connect(clientPort: clientPort, pid: 100)
        fixture.system.tableFailure = failure
        let identity = ExtensionAPICallerIdentity(designatedRequirement: Signatures.tinycastRequirement)
        #expect(await fixture.verifier.identityForPairing(peer()) == nil)
        #expect(await fixture.verifier.verify(peer(), matches: identity) == false)
        #expect(fixture.log.entries == [failure, failure])
    }

    @Test("A connection without OS-reported endpoints is refused")
    func noEndpoints() async {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.tinycast)
        fixture.system.connect(clientPort: clientPort, pid: 100)
        let identity = ExtensionAPICallerIdentity(designatedRequirement: Signatures.tinycastRequirement)
        for bare in [
            ExtensionAPIPeer(endpoint: nil),
            ExtensionAPIPeer(endpoint: peer().endpoint, localEndpoint: nil),
            ExtensionAPIPeer(endpoint: nil, localEndpoint: peer().localEndpoint),
        ] {
            #expect(await fixture.verifier.identityForPairing(bare) == nil)
            #expect(await fixture.verifier.verify(bare, matches: identity) == false)
        }
        #expect(fixture.log.entries == Array(repeating: .noConnectionPorts, count: 6))
    }

    @Test("A client paired without a recorded requirement is refused")
    func noRecordedRequirement() async {
        let fixture = VerifierFixture()
        fixture.system.launch(100, Signatures.tinycast)
        fixture.system.connect(clientPort: clientPort, pid: 100)
        #expect(await fixture.verifier.verify(peer(), matches: ExtensionAPICallerIdentity(designatedRequirement: nil)) == false)
        #expect(fixture.log.entries == [.noRecordedRequirement])
    }
}

// MARK: - Through the handler

@MainActor
struct CallerVerifierHandlerTests {
    private func makeFixture() -> (ExtensionAPIFixture, FakeCallerSystem) {
        let fixture = ExtensionAPIFixture()
        let system = FakeCallerSystem()
        fixture.verifier.delegate = CodeSigningCallerVerifier(inspector: system, onRefusal: { _ in })
        fixture.peer = peer()
        return (fixture, system)
    }

    @Test("Pairing stores the requirement the OS reports for the caller")
    func pairingStoresRequirement() async throws {
        let (fixture, system) = makeFixture()
        system.launch(100, Signatures.tinycast)
        system.connect(clientPort: clientPort, pid: 100)
        let signer = try await fixture.pair()
        let stored = fixture.store.clients.first { $0.id == signer.clientID }?.callerIdentity
        #expect(stored?.designatedRequirement == Signatures.tinycastRequirement)
    }

    @Test("An ad hoc or unsigned caller gets forbidden_caller and no prompt", arguments: [Signatures.adHoc, Signatures.unsigned])
    func adHocPairingForbidden(_ signature: CallerSignature) async {
        let (fixture, system) = makeFixture()
        system.launch(100, signature)
        system.connect(clientPort: clientPort, pid: 100)
        let response = await fixture.startPairing().value
        #expect(response.status == 403)
        #expect(errorCode(response) == "forbidden_caller")
        #expect(fixture.presenter.presented.isEmpty)
    }

    @Test("A signed request from another process gets forbidden_caller; the paired process passes")
    func otherProcessForbidden() async throws {
        let (fixture, system) = makeFixture()
        system.launch(100, Signatures.tinycast)
        system.launch(200, Signatures.curl)
        system.connect(clientPort: clientPort, pid: 100)
        let signer = try await fixture.pair()

        system.connect(clientPort: clientPort, pid: 200)
        let refused = await fixture.sendSigned(signer)
        #expect(refused.status == 403)
        #expect(errorCode(refused) == "forbidden_caller")

        system.connect(clientPort: clientPort, pid: 100)
        #expect(await fixture.sendSigned(signer).status == 200)
    }

    @Test("Pairing again replaces the requirement the extension's credentials carry")
    func repairingReplacesRequirement() async throws {
        let (fixture, system) = makeFixture()
        system.launch(100, Signatures.tinycast)
        system.connect(clientPort: clientPort, pid: 100)
        let first = try await fixture.pair()

        // Tinycast changes signing team and relaunches.
        system.exit(100)
        system.launch(400, Signatures.tinycastNewTeam)
        system.connect(clientPort: clientPort, pid: 400)
        #expect(await fixture.sendSigned(first).status == 403)

        let second = try await fixture.pair()
        let stored = fixture.store.clients.first { $0.id == second.clientID }?.callerIdentity
        #expect(stored?.designatedRequirement == Signatures.tinycastNewTeam.designatedRequirement)
        #expect(await fixture.sendSigned(second).status == 200)
    }

    @Test("The handler built without an explicit verifier checks the caller")
    func defaultVerifierChecksCaller() async {
        let handler = ExtensionAPIHandler(
            port: { 47615 },
            pairingStore: ExtensionAPIPairingStore(
                defaults: UserDefaults(suiteName: "CallerVerifierDefault-\(UUID().uuidString)")!,
                keychain: MockKeychainStore()
            ),
            loadPrompts: { [] },
            sessions: ExtensionAPISessionCatalog(context: nil, renderTranscript: { _ in nil })
        )
        let fixture = ExtensionAPIFixture()
        let admission = await handler.admit(fixture.pairHead(), peer: ExtensionAPIPeer(endpoint: nil))
        guard case .refused(let response) = admission else {
            Issue.record("pairing from an unidentifiable peer was admitted")
            return
        }
        #expect(response.status == 403)
        #expect(errorCode(response) == "forbidden_caller")
    }
}

// MARK: - Listener

/// Records the peer each admitted request came with.
private final class PeerRecordingHandler: ExtensionAPIRequestHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var _peers: [ExtensionAPIPeer] = []
    var peers: [ExtensionAPIPeer] { lock.withLock { _peers } }

    func admit(_ head: HTTPRequestHead, peer: ExtensionAPIPeer) async -> ExtensionAPIAdmission {
        lock.withLock { _peers.append(peer) }
        return .refused(HTTPResponse(status: 403))
    }

    func handle(_ head: HTTPRequestHead, body: Data, peer: ExtensionAPIPeer) async -> HTTPResponse {
        HTTPResponse(status: 500)
    }

    func apiDidStop() async {}
}

@Suite(.serialized)
struct CallerVerifierListenerTests {
    @Test("The listener reports the client's port and its own bound port for each connection")
    func peerCarriesBothPorts() async throws {
        let handler = PeerRecordingHandler()
        let listener = ExtensionAPIListener(
            handler: handler,
            limits: .init(maximumConnections: 4, headDeadline: .seconds(10), bodyGap: .seconds(30))
        )
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let client = try LoopbackClient(port: port)
        client.send("GET /v1/prompts HTTP/1.1\r\nHost: h\r\n\r\n")
        _ = client.readToEnd(timeout: 5)
        let recorded = try #require(handler.peers.first)
        guard case .hostPort(_, let local) = recorded.localEndpoint,
              case .hostPort(let remoteHost, let remote) = recorded.endpoint else {
            Issue.record("peer endpoints missing: \(recorded)")
            return
        }
        #expect(local.rawValue == port)
        #expect(remote.rawValue != port)
        #expect("\(remoteHost)".hasPrefix("127.0.0.1"))
    }
}

// MARK: - Connection table parsing

/// `net.inet.tcp.pcblist_n` captured on macOS 27.2 (Darwin 27.2.0): a process listening on
/// 127.0.0.1:47699 with one client connection from local port 60315, both in PID 74908 (uid 501).
/// Kernel pointers and TCP control blocks are zeroed. Records: header (0), accepted socket's
/// group (24), client socket's group (640: connection record, then socket record at 744),
/// listening socket's group (1256), trailer (1872).
private let capturedTable: [UInt8] = {
    let hex = [
        "18000000f40000000062050000000000365e28000000000068000000100000000000000000000000eb9bba53000000000000000000620500000000000000800000090000014000000000000000000000000000007f0000010000000000000000000000007f000001",
        "000000000000000000000000000000001830b4ba1200000068000000010000000000000000000000010000000400000000000200000000000000000006000000020000000000000000000000000000000000000000000000f50100009c24010000000000285e2800",
        "0000000080000000000800010200000000000000000000002000000002000000000000000000000000000000000000000000000000000000200000000400000000000000000000000000000000000000000000000000000088000000080000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "00000000000000000000000000000000cc000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000068000000100000000000000000000000ba53eb9b0000000000000000fe610500000000004008800000000000014000000000000000000000000000007f0000010000000000000000000000007f0000010000000000000000",
        "00000000000000006c9e35a41600000068000000010000000000000000000000010000000000000000000200000000000000000006000000020000000000000000000000000000000000000000000000f50100009c24010000000000275e28000000000080000020",
        "0009000403000000000000000400000020000000020000000000000000000000000000000000000000000000000000002000000004000000000000000000000000000000000000000000000000000000880000000800000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000cc0000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000680000001000000000000000000000000000ba530000000000000000fc61050000000000000080000000000001400000000000000000000000000000000000000000000000000000000000007f00000100000000000000000000000000000000",
        "000000001400000068000000010000000000000000000000010000000600000000000000000000000000000006000000020000000000000004000000000000000000000000000000f50100009c24010000000000265e280000000000000000000008000001000000",
        "0000000000000000200000000200000000000000000000000000000000000000000000000000000020000000040000000000000000000000000000000000000000000000000000008800000008000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "cc00000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "18000000f40000000062050000000000365e280000000000",
    ].joined()
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        bytes.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}()

private func setUInt32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
    withUnsafeBytes(of: value.littleEndian) { bytes.replaceSubrange(offset..<offset + 4, with: $0) }
}

private func owner(_ bytes: [UInt8], client: UInt16 = 60315, server: UInt16 = 47699) -> Result<TCPConnectionOwner, CallerRefusal> {
    Result { () throws(CallerRefusal) in try TCPConnectionTable.owner(in: Data(bytes), clientPort: client, serverPort: server) }
}

struct TCPConnectionTableTests {
    @Test("The client socket's owner is read from captured bytes")
    func capturedOwner() {
        #expect(capturedTable.count == 1896)
        #expect(owner(capturedTable) == .success(TCPConnectionOwner(pid: 74908, uid: 501)))
    }

    @Test("A port with no connection is not found")
    func unknownPort() {
        #expect(owner(capturedTable, client: 60316) == .failure(.connectionNotFound))
        #expect(owner(capturedTable, server: 47698) == .failure(.connectionNotFound))
    }

    @Test("A table with no connections is not found")
    func emptyTable() {
        let empty = Array(capturedTable[0..<24]) + Array(capturedTable[1872..<1896])
        #expect(owner(empty) == .failure(.connectionNotFound))
    }

    @Test("A matching record whose address is not loopback is not the client")
    func nonLoopbackAddress() {
        var bytes = capturedTable
        bytes[640 + 60] = 10 // foreign address 10.0.0.1
        #expect(owner(bytes) == .failure(.connectionNotFound))
    }

    @Test("Two records for the same client socket fail as ambiguous")
    func duplicateRecord() {
        let bytes = Array(capturedTable[0..<1872]) + Array(capturedTable[640..<1256]) + Array(capturedTable[1872...])
        #expect(owner(bytes) == .failure(.connectionAmbiguous))
    }

    @Test(
        "An unexpected layout fails closed",
        arguments: [
            ("header length", 0, UInt32(32)),
            ("connection record length", 640, UInt32(112)),
            ("socket record length", 744, UInt32(96)),
            ("record running past the end", 1256, UInt32(4000)),
            ("record shorter than its header", 640, UInt32(4)),
        ]
    )
    func unexpectedLayout(_ label: String, _ offset: Int, _ value: UInt32) {
        var bytes = capturedTable
        setUInt32(value, at: offset, in: &bytes)
        #expect(owner(bytes) == .failure(.unexpectedTableLayout), "\(label)")
    }

    @Test("A socket record with no connection record before it fails closed")
    func socketWithoutConnection() {
        var bytes = capturedTable
        setUInt32(0x2, at: 640 + 4, in: &bytes) // client group's connection record becomes another kind
        #expect(owner(bytes) == .failure(.unexpectedTableLayout))
    }

    @Test("A table cut short fails closed", arguments: [0, 10, 700, 1890])
    func truncated(_ length: Int) {
        #expect(owner(Array(capturedTable[0..<length])) == .failure(.unexpectedTableLayout))
    }
}

// MARK: - Live lookups

@Suite(.serialized)
struct LiveCallerProcessInspectorTests {
    @Test("The live table and audit token name this process as the owner of its own loopback client socket")
    func ownSocketOwner() async throws {
        let handler = PeerRecordingHandler()
        let listener = ExtensionAPIListener(
            handler: handler,
            limits: .init(maximumConnections: 4, headDeadline: .seconds(10), bodyGap: .seconds(30))
        )
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let client = try LoopbackClient(port: port)
        client.send("GET /v1/prompts HTTP/1.1\r\nHost: h\r\n\r\n")
        _ = client.readToEnd(timeout: 5)
        let recorded = try #require(handler.peers.first)
        guard case .hostPort(_, let remote) = recorded.endpoint else {
            Issue.record("peer endpoint missing: \(recorded)")
            return
        }
        let inspector = LiveCallerProcessInspector()
        let owner = try inspector.connectionOwner(clientPort: remote.rawValue, serverPort: port)
        #expect(owner.pid == getpid())
        #expect(owner.uid == getuid())
        let token = try inspector.auditToken(for: owner.pid)
        #expect(token.pid == getpid())
        #expect(throws: CallerRefusal.connectionNotFound) {
            try inspector.connectionOwner(clientPort: remote.rawValue, serverPort: port &+ 1)
        }
    }
}
