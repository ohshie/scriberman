import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppAudioService: AppAudioServiceProtocol {
    var runningApps: [CapturedApp] = []
    var selectedApp: CapturedApp? {
        didSet {
            guard !isApplyingSelection else {
                return
            }
            persistSelectedBundleID()
        }
    }

    private let runningApplicationProvider: RunningApplicationProviding
    private let userDefaults: UserDefaults
    private let usageStore: AppAudioUsageStore
    private let selectedAppBundleIDKey = "selectedAppBundleID"
    private var isApplyingSelection = false

    init(
        runningApplicationProvider: RunningApplicationProviding = NSWorkspaceRunningApplicationProvider(),
        userDefaults: UserDefaults = .standard
    ) {
        self.runningApplicationProvider = runningApplicationProvider
        self.userDefaults = userDefaults
        self.usageStore = AppAudioUsageStore(userDefaults: userDefaults)

        refreshRunningApps()
    }

    func incrementUsage(for bundleID: String) {
        usageStore.increment(bundleID: bundleID)
        runningApps = usageStore.sort(runningApps)
    }

    func refreshRunningApps() {
        runningApps = runningApplicationProvider.runningApplications()
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleID != nil }
            .filter { $0.bundleID != runningApplicationProvider.ownBundleIdentifier }
            .map { app in
                CapturedApp(
                    bundleID: app.bundleID ?? "",
                    name: app.name,
                    pid: app.pid,
                    icon: app.icon
                )
            }
        runningApps = usageStore.sort(runningApps)

        revalidateSelectedApp()
    }

    private func persistSelectedBundleID() {
        if let bundleID = selectedApp?.bundleID {
            userDefaults.set(bundleID, forKey: selectedAppBundleIDKey)
        } else {
            userDefaults.removeObject(forKey: selectedAppBundleIDKey)
        }
    }

    private func revalidateSelectedApp() {
        if let currentBundleID = selectedApp?.bundleID,
           let matchingCurrent = runningApps.first(where: { $0.bundleID == currentBundleID }) {
            applySelection(matchingCurrent)
            return
        }

        let savedBundleID = userDefaults.string(forKey: selectedAppBundleIDKey)
        if let savedBundleID,
           let restored = runningApps.first(where: { $0.bundleID == savedBundleID }) {
            applySelection(restored)
            return
        }

        if savedBundleID != nil {
            userDefaults.removeObject(forKey: selectedAppBundleIDKey)
        }

        applySelection(nil)
    }

    private func applySelection(_ app: CapturedApp?) {
        isApplyingSelection = true
        selectedApp = app
        isApplyingSelection = false
    }
}
