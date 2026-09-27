import Foundation
import Security
import Testing
@testable import Scriberman

struct KeychainStoreTests {
    private let service = "KeychainStoreTests"
    private let key = "api-key"

    @Test(arguments: [false, true])
    func saveRoundTripAndOverwrite(missingEntitlement: Bool) throws {
        let api = FakeSecurityAPI()
        if missingEntitlement { api.copyStatuses[0] = errSecMissingEntitlement }
        let store = LiveKeychainStore(service: service, security: api)
        try store.save(key: key, value: "first")
        #expect(store.read(key: key) == "first")
        try store.save(key: key, value: "second")
        #expect(store.read(key: key) == "second")
        #expect(api.updateVariants == [missingEntitlement ? 1 : 0])
        #expect(api.addQueries.allSatisfy {
            $0[kSecAttrAccessible] as? String == kSecAttrAccessibleWhenUnlocked as String
        })
    }

    @Test(arguments: [0, 1, 2, 3])
    func deleteRemovesAllPresentVariants(presence: Int) throws {
        let api = FakeSecurityAPI()
        for variant in 0...1 where presence & (1 << variant) != 0 {
            api.seed("value-\(variant)", service: service, key: key, variant: variant)
        }
        api.seed("unrelated", service: service, key: "other-key", variant: 1)
        api.seed("other-service", service: "other-service", key: key, variant: 0)
        let store = LiveKeychainStore(service: service, security: api)
        try store.delete(key: key)
        #expect(api.deleteVariants == [0, 1])
        #expect(store.read(key: key) == nil)
        #expect(api.value(service: service, key: "other-key", variant: 1) == "unrelated")
        #expect(api.value(service: "other-service", key: key, variant: 0) == "other-service")
    }

    @Test(arguments: [0, 1])
    func deleteAttemptsBothVariantsOnPermissionFailure(failingVariant: Int) {
        let api = FakeSecurityAPI()
        for variant in 0...1 { api.seed("value", service: service, key: key, variant: variant) }
        api.deleteStatuses[failingVariant] = errSecAuthFailed
        let store = LiveKeychainStore(service: service, security: api)
        expectStatus(errSecAuthFailed) { try store.delete(key: key) }
        #expect(api.deleteVariants == [0, 1])
        #expect(api.value(service: service, key: key, variant: 1 - failingVariant) == nil)
    }

    @Test
    func deleteReportsFirstFailure() {
        let api = FakeSecurityAPI()
        api.deleteStatuses = [0: errSecAuthFailed, 1: errSecInteractionNotAllowed]
        let store = LiveKeychainStore(service: service, security: api)
        expectStatus(errSecAuthFailed) { try store.delete(key: key) }
        #expect(api.deleteVariants == [0, 1])
    }

    @Test(arguments: [false, true])
    func deleteAllowsMissingEntitlementOnlyForDataProtection(legacyUnavailable: Bool) throws {
        let api = FakeSecurityAPI()
        api.deleteStatuses[0] = errSecMissingEntitlement
        api.seed("legacy", service: service, key: key, variant: 1)
        let store = LiveKeychainStore(service: service, security: api)
        if legacyUnavailable {
            api.deleteStatuses[1] = errSecMissingEntitlement
            expectStatus(errSecMissingEntitlement) { try store.delete(key: key) }
        } else {
            try store.delete(key: key)
            #expect(store.read(key: key) == nil)
        }
        #expect(api.deleteVariants == [0, 1])
    }

    @Test
    func legacyValueMigratesOnRead() {
        let api = FakeSecurityAPI()
        api.seed("legacy", service: service, key: key, variant: 1)
        let store = LiveKeychainStore(service: service, security: api)
        #expect(store.read(key: key) == "legacy")
        #expect(api.value(service: service, key: key, variant: 0) == "legacy")
        #expect(api.value(service: service, key: key, variant: 1) == nil)
        #expect(api.addQueries.first?[kSecAttrAccessible] as? String == kSecAttrAccessibleWhenUnlocked as String)
        #expect(api.deleteVariants == [1])
    }

    @Test
    func legacyReadWithoutEntitlementDoesNotMigrate() {
        let api = FakeSecurityAPI()
        api.copyStatuses[0] = errSecMissingEntitlement
        api.seed("legacy", service: service, key: key, variant: 1)
        let store = LiveKeychainStore(service: service, security: api)
        #expect(store.read(key: key) == "legacy")
        #expect(api.value(service: service, key: key, variant: 1) == "legacy")
        #expect(api.addQueries.isEmpty)
        #expect(api.deleteVariants.isEmpty)
    }

    @Test(arguments: [errSecAuthFailed, errSecMissingEntitlement, errSecDuplicateItem])
    func failedMigrationPreservesLegacyValue(status: OSStatus) {
        let api = FakeSecurityAPI()
        api.seed("legacy", service: service, key: key, variant: 1)
        api.addStatuses[0] = status
        let store = LiveKeychainStore(service: service, security: api)
        #expect(store.read(key: key) == "legacy")
        #expect(api.value(service: service, key: key, variant: 1) == "legacy")
        #expect(api.deleteVariants.isEmpty)
    }

    @Test
    func failedMigrationCleanupRetriesOnNextRead() {
        let api = FakeSecurityAPI()
        api.seed("legacy", service: service, key: key, variant: 1)
        api.deleteStatuses[1] = errSecAuthFailed
        let store = LiveKeychainStore(service: service, security: api)
        #expect(store.read(key: key) == "legacy")
        #expect(api.value(service: service, key: key, variant: 0) == "legacy")
        #expect(api.value(service: service, key: key, variant: 1) == "legacy")
        api.deleteStatuses.removeValue(forKey: 1)
        #expect(store.read(key: key) == "legacy")
        #expect(api.value(service: service, key: key, variant: 1) == nil)
    }

    @Test
    func protectedValueTakesPrecedence() {
        let api = FakeSecurityAPI()
        api.seed("current", service: service, key: key, variant: 0)
        api.seed("stale", service: service, key: key, variant: 1)
        let store = LiveKeychainStore(service: service, security: api)
        #expect(store.read(key: key) == "current")
        #expect(api.addQueries.isEmpty)
    }

    @Test
    func liveDefaultRoundTrip() throws {
        let store = LiveKeychainStore(service: "KeychainStoreTests.\(UUID().uuidString)")
        defer { try? store.delete(key: key) }
        #expect(store.read(key: key) == nil)
        try store.save(key: key, value: "first")
        #expect(store.read(key: key) == "first")
        try store.save(key: key, value: "second")
        #expect(store.read(key: key) == "second")
        try store.delete(key: key)
        #expect(store.read(key: key) == nil)
        try store.delete(key: key)
    }

    private func expectStatus(_ expected: OSStatus, operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected keychain failure \(expected)")
        } catch KeychainStoreError.unexpectedStatus(let actual) {
            #expect(actual == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private final class FakeSecurityAPI: SecurityAPI {
    private struct Item: Hashable {
        let service: String
        let account: String
    }

    private var stores: [[Item: Data]] = [[:], [:]]
    var copyStatuses: [Int: OSStatus] = [:]
    var addStatuses: [Int: OSStatus] = [:]
    var deleteStatuses: [Int: OSStatus] = [:]
    var deleteVariants: [Int] = []
    var updateVariants: [Int] = []
    var addQueries: [[CFString: Any]] = []

    func seed(_ value: String, service: String, key: String, variant: Int) {
        stores[variant][Item(service: service, account: key)] = Data(value.utf8)
    }

    func value(service: String, key: String, variant: Int) -> String? {
        stores[variant][Item(service: service, account: key)].flatMap { String(data: $0, encoding: .utf8) }
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let (variant, item, attributes) = decode(query)
        if let status = copyStatuses[variant] { return status }
        guard let data = stores[variant][item] else { return errSecItemNotFound }
        if attributes[kSecReturnData] as? Bool == true { result?.pointee = data as CFData }
        return errSecSuccess
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        let (variant, item, query) = decode(attributes)
        addQueries.append(query)
        if let status = addStatuses[variant] { return status }
        guard stores[variant][item] == nil else { return errSecDuplicateItem }
        guard let data = query[kSecValueData] as? Data else { return errSecParam }
        stores[variant][item] = data
        return errSecSuccess
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        let (variant, item, _) = decode(query)
        updateVariants.append(variant)
        guard stores[variant][item] != nil else { return errSecItemNotFound }
        stores[variant][item] = (attributes as NSDictionary)[kSecValueData] as? Data
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        let (variant, item, _) = decode(query)
        deleteVariants.append(variant)
        if let status = deleteStatuses[variant] { return status }
        return stores[variant].removeValue(forKey: item) == nil ? errSecItemNotFound : errSecSuccess
    }

    private func decode(_ query: CFDictionary) -> (Int, Item, [CFString: Any]) {
        let attributes = query as! [CFString: Any]
        #expect(attributes[kSecClass] as? String == kSecClassGenericPassword as String)
        let variant = attributes[kSecUseDataProtectionKeychain] as? Bool == true ? 0 : 1
        let item = Item(service: attributes[kSecAttrService] as! String, account: attributes[kSecAttrAccount] as! String)
        return (variant, item, attributes)
    }
}
