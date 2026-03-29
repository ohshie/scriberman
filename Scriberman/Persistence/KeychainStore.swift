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
        let query = baseQuery(for: key)
        let status = SecItemCopyMatching(query as CFDictionary, nil)

        if status == errSecSuccess {
            let attributes: [CFString: Any] = [kSecValueData: encodedValue]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(updateStatus)
            }
            return
        }

        guard status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }

        var createQuery = query
        createQuery[kSecValueData] = encodedValue
        createQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(createQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    func read(key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            return nil
        }

        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain: true,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
    }
}
