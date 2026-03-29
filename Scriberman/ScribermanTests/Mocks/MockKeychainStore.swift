import Foundation
@testable import Scriberman

final class MockKeychainStore: KeychainStore {
    private(set) var saveCalls: [(key: String, value: String)] = []
    private(set) var readCalls: [String] = []
    private(set) var deleteCalls: [String] = []
    private(set) var storage: [String: String] = [:]

    func save(key: String, value: String) throws {
        saveCalls.append((key, value))
        storage[key] = value
    }

    func read(key: String) -> String? {
        readCalls.append(key)
        return storage[key]
    }

    func delete(key: String) throws {
        deleteCalls.append(key)
        storage.removeValue(forKey: key)
    }
}
