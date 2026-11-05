import Darwin
import Foundation
import Security

/// Reads `net.inet.tcp.pcblist_n`, the kernel's TCP connection table.
///
/// The records are private kernel layouts (xnu `bsd/netinet/in_pcb.h` `xinpcb_n`,
/// `bsd/sys/socketvar.h` `xsocket_n`), packed to 4 bytes, each padded to 8 bytes in the stream.
/// The table opens and closes with an `xinpgen` record. A connection's records follow one
/// another: the connection record (`XSO_INPCB`), then its socket record (`XSO_SOCKET`), then
/// buffers, statistics and the TCP control block. Any record whose length differs from the
/// layout read here fails the lookup, so a changed layout refuses callers instead of misreading.
enum TCPConnectionTable {
    static let generationLength = 24
    static let connectionRecordLength = 104
    static let socketRecordLength = 104

    private static let kindSocket: UInt32 = 0x001
    private static let kindConnection: UInt32 = 0x010
    private static let ipv4Flag: UInt8 = 0x1

    // xinpcb_n offsets
    private static let foreignPortOffset = 16
    private static let localPortOffset = 18
    private static let versionFlagOffset = 44
    private static let foreignIPv4Offset = 60
    private static let localIPv4Offset = 76
    // xsocket_n offsets
    private static let uidOffset = 64
    private static let lastPIDOffset = 68

    private static let loopback: [UInt8] = [127, 0, 0, 1]

    /// The owner of the client socket `127.0.0.1:clientPort` → `127.0.0.1:serverPort`.
    static func owner(in table: Data, clientPort: UInt16, serverPort: UInt16) throws(CallerRefusal) -> TCPConnectionOwner {
        let bytes = [UInt8](table)
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        func networkUInt16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
        func padded(_ length: Int) -> Int { (length + 7) & ~7 }

        guard bytes.count >= generationLength, uint32(0) == generationLength else {
            throw .unexpectedTableLayout
        }
        var offset = padded(generationLength)
        var connection: Int?
        var owners: [TCPConnectionOwner] = []
        var closed = false
        while offset + 8 <= bytes.count {
            let length = Int(uint32(offset))
            if length == generationLength && offset + length == bytes.count {
                closed = true
                break
            }
            guard length >= 8, offset + length <= bytes.count else { throw .unexpectedTableLayout }
            switch uint32(offset + 4) {
            case kindConnection:
                guard length == connectionRecordLength else { throw .unexpectedTableLayout }
                connection = offset
            case kindSocket:
                guard length == socketRecordLength, let record = connection else { throw .unexpectedTableLayout }
                connection = nil
                let matches = bytes[record + versionFlagOffset] & ipv4Flag != 0
                    && networkUInt16(record + localPortOffset) == clientPort
                    && networkUInt16(record + foreignPortOffset) == serverPort
                    && Array(bytes[record + localIPv4Offset..<record + localIPv4Offset + 4]) == loopback
                    && Array(bytes[record + foreignIPv4Offset..<record + foreignIPv4Offset + 4]) == loopback
                if matches {
                    owners.append(TCPConnectionOwner(
                        pid: Int32(bitPattern: uint32(offset + lastPIDOffset)),
                        uid: uint32(offset + uidOffset)
                    ))
                }
            default:
                break
            }
            offset += padded(length)
        }
        guard closed else { throw .unexpectedTableLayout }
        guard let owner = owners.first else { throw .connectionNotFound }
        guard owners.count == 1 else { throw .connectionAmbiguous }
        return owner
    }
}

/// The real lookups: the kernel connection table, the process's audit token, and Security's code
/// checks through that token (never by PID).
struct LiveCallerProcessInspector: CallerProcessInspecting {
    func connectionOwner(clientPort: UInt16, serverPort: UInt16) throws(CallerRefusal) -> TCPConnectionOwner {
        try TCPConnectionTable.owner(in: readTable(), clientPort: clientPort, serverPort: serverPort)
    }

    private func readTable() throws(CallerRefusal) -> Data {
        let name = "net.inet.tcp.pcblist_n"
        // The table can grow between the size query and the read; retry with more room.
        for _ in 0..<3 {
            var length = 0
            guard sysctlbyname(name, nil, &length, nil, 0) == 0 else { throw .connectionTableUnreadable(errno) }
            length += 64 * 1024
            var buffer = [UInt8](repeating: 0, count: length)
            if sysctlbyname(name, &buffer, &length, nil, 0) == 0 {
                return Data(buffer[0..<length])
            }
            guard errno == ENOMEM else { throw .connectionTableUnreadable(errno) }
        }
        throw .connectionTableUnreadable(ENOMEM)
    }

    func auditToken(for pid: Int32) throws(CallerRefusal) -> CallerAuditToken {
        var task: mach_port_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS else { throw .auditTokenUnavailable }
        defer { mach_port_deallocate(mach_task_self_, task) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw .auditTokenUnavailable }
        let words = withUnsafeBytes(of: &token) { Array($0.bindMemory(to: UInt32.self)) }
        return CallerAuditToken(words: words)
    }

    private func code(for token: CallerAuditToken) throws(CallerRefusal) -> SecCode {
        let data = token.words.withUnsafeBytes { Data($0) }
        let attributes = [kSecGuestAttributeAudit: data] as CFDictionary
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard status == errSecSuccess, let code else { throw .codeUnavailable(status) }
        return code
    }

    func signature(of token: CallerAuditToken) throws(CallerRefusal) -> CallerSignature {
        let code = try code(for: token)
        var signature = CallerSignature(
            validity: SecCodeCheckValidity(code, [], nil),
            isAdHoc: false,
            designatedRequirement: nil,
            identifier: nil,
            teamIdentifier: nil
        )
        var staticCode: SecStaticCode?
        var status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw .codeUnavailable(status) }
        var information: CFDictionary?
        status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard status == errSecSuccess, let information = information as? [String: Any] else {
            throw .codeUnavailable(status)
        }
        let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        signature.isAdHoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        signature.identifier = information[kSecCodeInfoIdentifier as String] as? String
        signature.teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
        var requirement: SecRequirement?
        var text: CFString?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
           SecRequirementCopyString(requirement, [], &text) == errSecSuccess {
            signature.designatedRequirement = text as String?
        }
        return signature
    }

    func validity(of token: CallerAuditToken, against requirement: String) throws(CallerRefusal) -> OSStatus {
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else { throw .requirementUnreadable(status) }
        return SecCodeCheckValidity(try code(for: token), [], compiled)
    }
}
