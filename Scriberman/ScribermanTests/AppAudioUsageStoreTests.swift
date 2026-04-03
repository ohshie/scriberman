import Foundation
import Testing
@testable import Scriberman

final class AppAudioUsageStoreTests {
    private var userDefaults: UserDefaults!
    private var suiteName: String!

    init() {
        suiteName = "AppAudioUsageStoreTests.\(UUID().uuidString)"
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
    func testSortOrdersByUsageThenNameThenBundleID() {
        userDefaults.set(
            [
                "com.test.bravo": 3,
                "com.test.charlie": 1
            ],
            forKey: "appAudioUsageScores"
        )

        let store = AppAudioUsageStore(userDefaults: userDefaults)
        let apps = [
            CapturedApp(bundleID: "com.test.bravo", name: "Zulu", pid: 1, icon: nil),
            CapturedApp(bundleID: "com.test.alpha", name: "Alpha", pid: 2, icon: nil),
            CapturedApp(bundleID: "com.test.beta", name: "Alpha", pid: 3, icon: nil),
            CapturedApp(bundleID: "com.test.charlie", name: "Bravo", pid: 4, icon: nil)
        ]

        let sorted = store.sort(apps)

        #expect(
            sorted.map(\.bundleID)
                == ["com.test.bravo", "com.test.charlie", "com.test.alpha", "com.test.beta"]
        )
    }

    @MainActor
    @Test
    func testIncrementPersistsScores() {
        let store = AppAudioUsageStore(userDefaults: userDefaults)

        store.increment(bundleID: "com.test.spotify")
        store.increment(bundleID: "com.test.spotify")

        let persistedScores = userDefaults.dictionary(forKey: "appAudioUsageScores") as? [String: Int]
        #expect(persistedScores?["com.test.spotify"] == 2)
    }

    @MainActor
    @Test
    func testInitLoadsPersistedScoresForSorting() {
        userDefaults.set(["com.test.music": 5], forKey: "appAudioUsageScores")

        let store = AppAudioUsageStore(userDefaults: userDefaults)
        let apps = [
            CapturedApp(bundleID: "com.test.browser", name: "Browser", pid: 1, icon: nil),
            CapturedApp(bundleID: "com.test.music", name: "Music", pid: 2, icon: nil)
        ]

        #expect(store.sort(apps).map(\.bundleID) == ["com.test.music", "com.test.browser"])
    }
}
