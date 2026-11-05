import CryptoKit
import Foundation

/// HMAC-SHA256 request and response signatures of API contract v1. Every value is lowercase hex.
enum ExtensionAPISigning {
    static let clientHeader = "X-Scriberman-Client"
    static let timestampHeader = "X-Scriberman-Timestamp"
    static let nonceHeader = "X-Scriberman-Nonce"
    static let bodyHashHeader = "X-Scriberman-Body-SHA256"
    static let signatureHeader = "X-Scriberman-Signature"

    static let requestHeaders = [clientHeader, timestampHeader, nonceHeader, bodyHashHeader, signatureHeader]

    /// Whether `value` is `byteCount` bytes written as lowercase hex.
    static func isHex(_ value: String, byteCount: Int) -> Bool {
        value.utf8.count == byteCount * 2 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        String(bytes.flatMap { byte -> [Character] in
            let digits = Array("0123456789abcdef")
            return [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
        })
    }

    /// Lowercase hex to bytes; nil when it isn't lowercase hex.
    static func bytes(fromHex value: String) -> Data? {
        guard value.utf8.count.isMultiple(of: 2), isHex(value, byteCount: value.utf8.count / 2) else { return nil }
        var data = Data(capacity: value.utf8.count / 2)
        var high: UInt8?
        for char in value.utf8 {
            let nibble = char <= 57 ? char - 48 : char - 87
            if let pending = high {
                data.append(pending << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return data
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Whether `signatureHex` is the request signature over the head fields. Compared in
    /// constant time.
    static func isValidRequestSignature(
        _ signatureHex: String,
        method: String,
        target: String,
        timestamp: String,
        nonce: String,
        bodyHash: String,
        secret: Data
    ) -> Bool {
        guard isHex(signatureHex, byteCount: 32), let signature = bytes(fromHex: signatureHex) else { return false }
        let message = [method, target, timestamp, nonce, bodyHash].joined(separator: "\n")
        return HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data(message.utf8), using: SymmetricKey(data: secret))
    }

    /// The response with its signature header over the request nonce, status and body hash.
    static func sign(_ response: HTTPResponse, nonce: String, secret: Data) -> HTTPResponse {
        let message = [nonce, String(response.status), sha256Hex(response.body)].joined(separator: "\n")
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: secret))
        let headers = response.headers.filter { $0.name.caseInsensitiveCompare(signatureHeader) != .orderedSame }
        return HTTPResponse(
            status: response.status,
            headers: headers + [.init(name: signatureHeader, value: hex(code))],
            body: response.body
        )
    }
}
