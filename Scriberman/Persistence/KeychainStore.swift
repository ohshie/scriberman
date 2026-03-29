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

struct LiveKeychainStore: KeychainStore {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "Scriberman") {
        self.service = service
    }

    func save(key: String, value: String) throws {
        let encodedValue = Data(value.utf8)
        for (index, baseQuery) in queryVariants(for: key).enumerated() {
            var query = baseQuery
            let status = SecItemCopyMatching(query as CFDictionary, nil)

            if status == errSecSuccess {
                let attributes: [CFString: Any] = [kSecValueData: encodedValue]
                let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
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
                let addStatus = SecItemAdd(query as CFDictionary, nil)
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
        for (index, baseQuery) in queryVariants(for: key).enumerated() {
            var query = baseQuery
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess {
                guard let data = result as? Data else {
                    return nil
                }
                return String(data: data, encoding: .utf8)
            }

            if status == errSecItemNotFound || shouldFallback(status: status, variantIndex: index) {
                continue
            }
            return nil
        }

        return nil
    }

    func delete(key: String) throws {
        var sawItemNotFound = false

        for (index, query) in queryVariants(for: key).enumerated() {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess {
                return
            }
            if status == errSecItemNotFound {
                sawItemNotFound = true
                continue
            }
            if shouldFallback(status: status, variantIndex: index) {
                continue
            }
            throw KeychainStoreError.unexpectedStatus(status)
        }

        if sawItemNotFound {
            return
        }

        throw KeychainStoreError.unexpectedStatus(errSecMissingEntitlement)
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
