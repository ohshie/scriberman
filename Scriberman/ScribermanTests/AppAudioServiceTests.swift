import AppKit
import XCTest
@testable import Scriberman

final class AppAudioServiceTests: XCTestCase {
    private var provider: MockRunningApplicationProvider!
    private var userDefaults: UserDefaults!
    private var service: AppAudioService!
    private var userDefaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        provider = MockRunningApplicationProvider()
        userDefaultsSuiteName = "AppAudioServiceTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }

    override func tearDown() {
        service = nil
        if let userDefaultsSuiteName {
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        userDefaults = nil
        userDefaultsSuiteName = nil
        provider = nil
        super.tearDown()
    }

    @MainActor
    func testRefreshRunningAppsFiltersRegularAndExcludesOwnBundleID() {
        provider.ownBundleIdentifier = "com.test.scriberman"
        provider.apps = [
            RunningApplicationSnapshot(bundleID: "com.test.scriberman", name: "Scriberman", pid: 1, icon: nil, activationPolicy: .regular),
            RunningApplicationSnapshot(bundleID: "com.test.zoom", name: "Zoom", pid: 2, icon: nil, activationPolicy: .regular),
            RunningApplicationSnapshot(bundleID: "com.test.agent", name: "Agent", pid: 3, icon: nil, activationPolicy: .accessory),
            RunningApplicationSnapshot(bundleID: nil, name: "No Bundle", pid: 4, icon: nil, activationPolicy: .regular)
        ]

        service = AppAudioService(
            runningApplicationProvider: provider,
            userDefaults: userDefaults
        )

        XCTAssertEqual(service.runningApps.map(\.bundleID), ["com.test.zoom"])
    }

    @MainActor
    func testRefreshRunningAppsSortsByUsageThenNameThenBundleID() {
        provider.apps = [
            RunningApplicationSnapshot(bundleID: "com.test.spotify", name: "Spotify", pid: 1, icon: nil, activationPolicy: .regular),
            RunningApplicationSnapshot(bundleID: "com.test.chrome", name: "Chrome", pid: 2, icon: nil, activationPolicy: .regular),
            RunningApplicationSnapshot(bundleID: "com.test.alpha", name: "Alpha", pid: 3, icon: nil, activationPolicy: .regular),
            RunningApplicationSnapshot(bundleID: "com.test.beta", name: "Alpha", pid: 4, icon: nil, activationPolicy: .regular)
        ]
        userDefaults.set(
            [
                "com.test.spotify": 10,
                "com.test.chrome": 3
            ],
            forKey: "appAudioUsageScores"
        )

        service = AppAudioService(
            runningApplicationProvider: provider,
            userDefaults: userDefaults
        )

        XCTAssertEqual(
            service.runningApps.map(\.bundleID),
            ["com.test.spotify", "com.test.chrome", "com.test.alpha", "com.test.beta"]
        )
    }

    @MainActor
    func testSelectedAppPersistsBundleID() {
        provider.apps = [
            RunningApplicationSnapshot(bundleID: "com.test.zoom", name: "Zoom", pid: 2, icon: nil, activationPolicy: .regular)
        ]
        service = AppAudioService(
            runningApplicationProvider: provider,
            userDefaults: userDefaults
        )

        service.selectedApp = service.runningApps.first

        XCTAssertEqual(userDefaults.string(forKey: "selectedAppBundleID"), "com.test.zoom")
    }

    @MainActor
    func testRestoreSelectionFromSavedBundleID() {
        provider.apps = [
            RunningApplicationSnapshot(bundleID: "com.test.zoom", name: "Zoom", pid: 2, icon: nil, activationPolicy: .regular),
            RunningApplicationSnapshot(bundleID: "com.test.browser", name: "Browser", pid: 9, icon: nil, activationPolicy: .regular)
        ]
        userDefaults.set("com.test.browser", forKey: "selectedAppBundleID")

        service = AppAudioService(
            runningApplicationProvider: provider,
            userDefaults: userDefaults
        )

        XCTAssertEqual(service.selectedApp?.bundleID, "com.test.browser")
    }

    @MainActor
    func testMissingSavedSelectionIsClearedAndSelectionIsNil() {
        provider.apps = [
            RunningApplicationSnapshot(bundleID: "com.test.zoom", name: "Zoom", pid: 2, icon: nil, activationPolicy: .regular)
        ]
        userDefaults.set("com.test.missing", forKey: "selectedAppBundleID")

        service = AppAudioService(
            runningApplicationProvider: provider,
            userDefaults: userDefaults
        )

        XCTAssertNil(service.selectedApp)
        XCTAssertNil(userDefaults.string(forKey: "selectedAppBundleID"))
    }

    @MainActor
    func testRefreshRevalidatesSelectionWhenAppDisappears() {
        provider.apps = [
            RunningApplicationSnapshot(bundleID: "com.test.zoom", name: "Zoom", pid: 2, icon: nil, activationPolicy: .regular),
            RunningApplicationSnapshot(bundleID: "com.test.browser", name: "Browser", pid: 9, icon: nil, activationPolicy: .regular)
        ]
        service = AppAudioService(
            runningApplicationProvider: provider,
            userDefaults: userDefaults
        )

        service.selectedApp = service.runningApps.first(where: { $0.bundleID == "com.test.zoom" })

        provider.apps = [
            RunningApplicationSnapshot(bundleID: "com.test.browser", name: "Browser", pid: 9, icon: nil, activationPolicy: .regular)
        ]

        service.refreshRunningApps()

        XCTAssertNil(service.selectedApp)
        XCTAssertNil(userDefaults.string(forKey: "selectedAppBundleID"))
    }

    @MainActor
    func testIncrementUsagePersistsAndResortsRunningApps() {
        provider.apps = [
            RunningApplicationSnapshot(bundleID: "com.test.zoom", name: "Zoom", pid: 1, icon: nil, activationPolicy: .regular),
            RunningApplicationSnapshot(bundleID: "com.test.browser", name: "Browser", pid: 2, icon: nil, activationPolicy: .regular)
        ]
        service = AppAudioService(
            runningApplicationProvider: provider,
            userDefaults: userDefaults
        )

        XCTAssertEqual(service.runningApps.map(\.bundleID), ["com.test.browser", "com.test.zoom"])

        service.incrementUsage(for: "com.test.zoom")

        XCTAssertEqual(service.runningApps.map(\.bundleID), ["com.test.zoom", "com.test.browser"])
        let persistedScores = userDefaults.dictionary(forKey: "appAudioUsageScores") as? [String: Int]
        XCTAssertEqual(persistedScores?["com.test.zoom"], 1)
    }
}

private final class MockRunningApplicationProvider: RunningApplicationProviding {
    var ownBundleIdentifier: String?
    var apps: [RunningApplicationSnapshot] = []

    func runningApplications() -> [RunningApplicationSnapshot] {
        apps
    }
}
