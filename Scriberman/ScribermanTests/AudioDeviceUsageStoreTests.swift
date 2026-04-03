import CoreAudio
import Foundation
import Testing
@testable import Scriberman

final class AudioDeviceUsageStoreTests {
    private var userDefaults: UserDefaults!
    private var suiteName: String!

    init() {
        suiteName = "AudioDeviceUsageStoreTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        if let suiteName {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        userDefaults = nil
        suiteName = nil
    }

    @MainActor
    @Test
    func testSortOrdersByUsageThenNameThenUID() {
        userDefaults.set(["uid-1": 2, "uid-3": 1], forKey: "deviceUsageScores")

        let store = AudioDeviceUsageStore(userDefaults: userDefaults)
        let devices = [
            AudioInputDevice(id: AudioDeviceID(1), uid: "uid-1", name: "Zulu Mic"),
            AudioInputDevice(id: AudioDeviceID(2), uid: "uid-2", name: "Alpha Mic"),
            AudioInputDevice(id: AudioDeviceID(3), uid: "uid-3", name: "Bravo Mic"),
            AudioInputDevice(id: AudioDeviceID(4), uid: "uid-4", name: "Alpha Mic")
        ]

        let sorted = store.sort(devices)

        #expect(sorted.map(\.uid) == ["uid-1", "uid-3", "uid-2", "uid-4"])
    }

    @MainActor
    @Test
    func testIncrementPersistsScores() {
        let store = AudioDeviceUsageStore(userDefaults: userDefaults)

        store.increment(uid: "uid-7")
        store.increment(uid: "uid-7")

        let persistedScores = userDefaults.dictionary(forKey: "deviceUsageScores") as? [String: Int]
        #expect(persistedScores?["uid-7"] == 2)
    }

    @MainActor
    @Test
    func testInitLoadsPersistedScoresForSorting() {
        userDefaults.set(["uid-2": 5], forKey: "deviceUsageScores")

        let store = AudioDeviceUsageStore(userDefaults: userDefaults)
        let devices = [
            AudioInputDevice(id: AudioDeviceID(1), uid: "uid-1", name: "Mic One"),
            AudioInputDevice(id: AudioDeviceID(2), uid: "uid-2", name: "Mic Two")
        ]

        #expect(store.sort(devices).map(\.uid) == ["uid-2", "uid-1"])
    }
}
