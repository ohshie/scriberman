import Foundation
@testable import Scriberman

final class MockKeychainStore: KeychainStore {
    struct Failure: Error {}

    private(set) var saveCalls: [(key: String, value: String)] = []
    private(set) var readCalls: [String] = []
    private(set) var deleteCalls: [String] = []
    private(set) var storage: [String: String] = [:]

    /// When set, saves throw and store nothing.
    var failsSaves = false
    /// When set, reads fail: `read` returns nil and `readIfPresent` throws.
    var failsReads = false
    /// When set, deletes throw and remove nothing.
    var failsDeletes = false

    func save(key: String, value: String) throws {
        saveCalls.append((key, value))
        if failsSaves { throw Failure() }
        storage[key] = value
    }

    func read(key: String) -> String? {
        (try? readIfPresent(key: key)) ?? nil
    }

    func readIfPresent(key: String) throws -> String? {
        readCalls.append(key)
        if failsReads { throw Failure() }
        return storage[key]
    }

    func delete(key: String) throws {
        deleteCalls.append(key)
        if failsDeletes { throw Failure() }
        storage.removeValue(forKey: key)
    }

    /// Removes an item behind the store's back, as if it had gone missing from the Keychain.
    func removeOutsideStore(key: String) {
        storage.removeValue(forKey: key)
    }
}
