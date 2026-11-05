import Foundation
import Network
import OSLog
import Security

/// What the operating system reports about the other end of a connection. Never filled from
/// request headers.
struct ExtensionAPIPeer: Sendable, Equatable {
    /// The connection's remote endpoint, as `NWConnection.endpoint` reports it.
    let endpoint: NWEndpoint?
    /// The connection's local endpoint (the listener's address and port), as the connection's
    /// current path reports it.
    var localEndpoint: NWEndpoint? = nil
}

/// The caller's code-signing identity, recorded at pairing and kept with the client.
struct ExtensionAPICallerIdentity: Codable, Equatable, Sendable {
    /// The caller's designated requirement, as text. Later requests must satisfy it.
    var designatedRequirement: String?
    /// The signing identifier the OS verified at pairing, for display next to the claimed name.
    var signingIdentifier: String? = nil
    /// The signing team the OS verified at pairing, if the signature has one.
    var teamIdentifier: String? = nil
}

/// Decides whether the process at the other end of a connection may use the API.
protocol ExtensionAPICallerVerifier: Sendable {
    /// At pairing: the identity to store with the new client, or nil to refuse the caller.
    func identityForPairing(_ peer: ExtensionAPIPeer) async -> ExtensionAPICallerIdentity?
    /// On a signed request: whether the caller still has the identity recorded at pairing.
    func verify(_ peer: ExtensionAPIPeer, matches identity: ExtensionAPICallerIdentity) async -> Bool
}

/// Why a caller was refused. Every failure refuses: the verifier fails closed.
enum CallerRefusal: Error, Equatable, Sendable {
    /// The connection's client or server port is unknown.
    case noConnectionPorts
    /// The kernel connection table could not be read (errno).
    case connectionTableUnreadable(Int32)
    /// No record in the table matches the connection.
    case connectionNotFound
    /// More than one record matches the connection.
    case connectionAmbiguous
    /// The table's records don't have the layout this build reads.
    case unexpectedTableLayout
    /// No audit token for the socket's process (it exited, or the call failed).
    case auditTokenUnavailable
    /// Another process owns the socket after the audit token was taken.
    case ownerChanged
    /// No code object for the audit token (the process exited, or its code can't be read).
    case codeUnavailable(OSStatus)
    /// The signature is missing or invalid.
    case invalidSignature(OSStatus)
    /// The signature is ad hoc: nothing identifies its signer.
    case adHocSignature
    /// The code has no designated requirement to record.
    case noDesignatedRequirement
    /// The client was paired without a recorded requirement.
    case noRecordedRequirement
    /// The recorded requirement can't be compiled.
    case requirementUnreadable(OSStatus)
    /// The caller doesn't satisfy the recorded requirement.
    case requirementNotSatisfied(OSStatus)
}

/// The process that last used a socket, from the kernel connection table.
struct TCPConnectionOwner: Equatable, Sendable {
    let pid: Int32
    let uid: UInt32
}

/// A process's audit token. Its PID version tells a reused PID apart from the original process.
struct CallerAuditToken: Equatable, Sendable {
    /// The eight words of `audit_token_t`.
    let words: [UInt32]

    init(words: [UInt32]) {
        self.words = words
    }

    /// A token naming `pid` at `pidVersion`, with the other words zero.
    init(pid: Int32, pidVersion: UInt32) {
        var words = [UInt32](repeating: 0, count: 8)
        words[5] = UInt32(bitPattern: pid)
        words[7] = pidVersion
        self.words = words
    }

    var pid: Int32 { Int32(bitPattern: words[5]) }
    var pidVersion: UInt32 { words[7] }
}

/// What the OS reports about a running process's code signature.
struct CallerSignature: Equatable, Sendable {
    /// Result of validating the running code's signature, `errSecSuccess` when valid.
    var validity: OSStatus
    var isAdHoc: Bool
    var designatedRequirement: String?
    var identifier: String?
    var teamIdentifier: String?
}

/// The operating-system lookups the verifier needs, behind one seam.
protocol CallerProcessInspecting: Sendable {
    /// The process that owns the client socket `127.0.0.1:clientPort` → `127.0.0.1:serverPort`.
    func connectionOwner(clientPort: UInt16, serverPort: UInt16) throws(CallerRefusal) -> TCPConnectionOwner
    func auditToken(for pid: Int32) throws(CallerRefusal) -> CallerAuditToken
    /// The signature of the process the token names, looked up by token only.
    func signature(of token: CallerAuditToken) throws(CallerRefusal) -> CallerSignature
    /// Validates the token's process against `requirement`; `errSecSuccess` when it satisfies it.
    func validity(of token: CallerAuditToken, against requirement: String) throws(CallerRefusal) -> OSStatus
}

/// Identifies the caller from the kernel connection table and checks its code signature through
/// its audit token. Pairing records the caller's designated requirement; later requests must
/// satisfy it.
struct CodeSigningCallerVerifier: ExtensionAPICallerVerifier {
    private static let logger = Logger(subsystem: "Scriberman", category: "ExtensionAPICallerVerifier")

    private let inspector: any CallerProcessInspecting
    private let onRefusal: @Sendable (CallerRefusal) -> Void

    init(
        inspector: any CallerProcessInspecting = LiveCallerProcessInspector(),
        onRefusal: @escaping @Sendable (CallerRefusal) -> Void = CodeSigningCallerVerifier.log
    ) {
        self.inspector = inspector
        self.onRefusal = onRefusal
    }

    static func log(_ refusal: CallerRefusal) {
        logger.error("Caller refused: \(String(describing: refusal), privacy: .public)")
    }

    func identityForPairing(_ peer: ExtensionAPIPeer) async -> ExtensionAPICallerIdentity? {
        do throws(CallerRefusal) {
            let token = try caller(of: peer)
            let signature = try inspector.signature(of: token)
            guard signature.validity == errSecSuccess else { throw .invalidSignature(signature.validity) }
            guard !signature.isAdHoc else { throw .adHocSignature }
            guard let requirement = signature.designatedRequirement else { throw .noDesignatedRequirement }
            return ExtensionAPICallerIdentity(
                designatedRequirement: requirement,
                signingIdentifier: signature.identifier,
                teamIdentifier: signature.teamIdentifier
            )
        } catch {
            onRefusal(error)
            return nil
        }
    }

    func verify(_ peer: ExtensionAPIPeer, matches identity: ExtensionAPICallerIdentity) async -> Bool {
        do throws(CallerRefusal) {
            guard let requirement = identity.designatedRequirement else { throw .noRecordedRequirement }
            let token = try caller(of: peer)
            let status = try inspector.validity(of: token, against: requirement)
            guard status == errSecSuccess else { throw .requirementNotSatisfied(status) }
            return true
        } catch {
            onRefusal(error)
            return false
        }
    }

    /// The audit token of the process that owns the peer's socket. The table is read again after
    /// the token is taken, so a socket handed to another process in between is refused.
    private func caller(of peer: ExtensionAPIPeer) throws(CallerRefusal) -> CallerAuditToken {
        guard case .hostPort(_, let client) = peer.endpoint,
              case .hostPort(_, let server) = peer.localEndpoint else {
            throw .noConnectionPorts
        }
        let owner = try inspector.connectionOwner(clientPort: client.rawValue, serverPort: server.rawValue)
        let token = try inspector.auditToken(for: owner.pid)
        guard token.pid == owner.pid else { throw .auditTokenUnavailable }
        let recheck = try inspector.connectionOwner(clientPort: client.rawValue, serverPort: server.rawValue)
        guard recheck.pid == owner.pid else { throw .ownerChanged }
        return token
    }
}
