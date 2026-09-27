import Foundation
import Security

protocol KeychainStore {
    func save(key: String, value: String) throws
    func read(key: String) -> String?
    func delete(key: String) throws
}

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            if status == errSecMissingEntitlement {
                return "Keychain access failed (missing entitlement/signing context: \(status))."
            }
            return "Keychain operation failed with status: \(status)"
        case .invalidData:
            return "Stored keychain value is not valid UTF-8."
        }
    }
}

protocol SecurityAPI {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct LiveSecurityAPI: SecurityAPI {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        SecItemAdd(attributes, nil)
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

struct LiveKeychainStore: KeychainStore {
    private let service: String
    private let security: any SecurityAPI

    init(service: String = Bundle.main.bundleIdentifier ?? "Scriberman", security: any SecurityAPI = LiveSecurityAPI()) {
        self.service = service
        self.security = security
    }

    func save(key: String, value: String) throws {
        let encodedValue = Data(value.utf8)
        for (index, baseQuery) in queryVariants(for: key).enumerated() {
            var query = baseQuery
            let status = security.copyMatching(query as CFDictionary, nil)

            if status == errSecSuccess {
                let attributes: [CFString: Any] = [kSecValueData: encodedValue]
                let updateStatus = security.update(query as CFDictionary, attributes as CFDictionary)
                if updateStatus == errSecSuccess {
                    return
                }
                if shouldFallback(status: updateStatus, variantIndex: index) {
                    continue
                }
                throw KeychainStoreError.unexpectedStatus(updateStatus)
            }

            if status == errSecItemNotFound {
                query[kSecValueData] = encodedValue
                query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
                let addStatus = security.add(query as CFDictionary)
                if addStatus == errSecSuccess {
                    return
                }
                if shouldFallback(status: addStatus, variantIndex: index) {
                    continue
                }
                throw KeychainStoreError.unexpectedStatus(addStatus)
            }

            if shouldFallback(status: status, variantIndex: index) {
                continue
            }
            throw KeychainStoreError.unexpectedStatus(status)
        }

        throw KeychainStoreError.unexpectedStatus(errSecMissingEntitlement)
    }

    func read(key: String) -> String? {
        let variants = queryVariants(for: key)
        var dataProtectionItemMissing = false
        for (index, baseQuery) in variants.enumerated() {
            var query = baseQuery
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = security.copyMatching(query as CFDictionary, &result)
            if status == errSecSuccess {
                guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                    return nil
                }
                if index == 0 {
                    // Retry cleanup if an earlier migration could not remove the legacy copy.
                    _ = security.delete(variants[1] as CFDictionary)
                } else if dataProtectionItemMissing {
                    var destination = variants[0]
                    destination[kSecValueData] = data
                    destination[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
                    if security.add(destination as CFDictionary) == errSecSuccess {
                        _ = security.delete(baseQuery as CFDictionary)
                    }
                }
                return value
            }

            if index == 0 && status == errSecItemNotFound {
                dataProtectionItemMissing = true
            }
            if status == errSecItemNotFound || shouldFallback(status: status, variantIndex: index) {
                continue
            }
            return nil
        }

        return nil
    }

    func delete(key: String) throws {
        var firstFailure: OSStatus?

        for (index, query) in queryVariants(for: key).enumerated() {
            let status = security.delete(query as CFDictionary)
            if status == errSecSuccess || status == errSecItemNotFound || shouldFallback(status: status, variantIndex: index) {
                continue
            }
            if firstFailure == nil {
                firstFailure = status
            }
        }

        if let firstFailure {
            throw KeychainStoreError.unexpectedStatus(firstFailure)
        }
    }

    private func queryVariants(for key: String) -> [[CFString: Any]] {
        [
            baseQuery(for: key, useDataProtectionKeychain: true),
            baseQuery(for: key, useDataProtectionKeychain: false),
        ]
    }

    private func shouldFallback(status: OSStatus, variantIndex: Int) -> Bool {
        variantIndex == 0 && status == errSecMissingEntitlement
    }

    private func baseQuery(for key: String, useDataProtectionKeychain: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
        }
        return query
    }
}
