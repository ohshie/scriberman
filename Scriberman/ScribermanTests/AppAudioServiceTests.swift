import AppKit
import XCTest
@testable import Scriberman

@MainActor
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
}

private final class MockRunningApplicationProvider: RunningApplicationProviding {
    var ownBundleIdentifier: String?
    var apps: [RunningApplicationSnapshot] = []

    func runningApplications() -> [RunningApplicationSnapshot] {
        apps
    }
}
