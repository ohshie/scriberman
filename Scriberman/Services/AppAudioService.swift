import AppKit
import Combine
import Foundation

struct RunningApplicationSnapshot {
    let bundleID: String?
    let name: String
    let pid: pid_t
    let icon: NSImage?
    let activationPolicy: NSApplication.ActivationPolicy
}

protocol RunningApplicationProviding {
    var ownBundleIdentifier: String? { get }
    func runningApplications() -> [RunningApplicationSnapshot]
}

struct NSWorkspaceRunningApplicationProvider: RunningApplicationProviding {
    var ownBundleIdentifier: String? {
        Bundle.main.bundleIdentifier
    }

    func runningApplications() -> [RunningApplicationSnapshot] {
        NSWorkspace.shared.runningApplications.map { app in
            RunningApplicationSnapshot(
                bundleID: app.bundleIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "Unknown App",
                pid: app.processIdentifier,
                icon: app.icon,
                activationPolicy: app.activationPolicy
            )
        }
    }
}

@MainActor
protocol AppAudioServiceProtocol: AnyObject {
    var runningApps: [CapturedApp] { get }
    var selectedApp: CapturedApp? { get set }
    var runningAppsPublisher: AnyPublisher<[CapturedApp], Never> { get }
    var selectedAppPublisher: AnyPublisher<CapturedApp?, Never> { get }
    func refreshRunningApps()
}

@MainActor
final class AppAudioService: ObservableObject, AppAudioServiceProtocol {
    @Published var runningApps: [CapturedApp] = []
    @Published var selectedApp: CapturedApp? {
        didSet {
            guard !isApplyingSelection else {
                return
            }
            persistSelectedBundleID()
        }
    }

    var runningAppsPublisher: AnyPublisher<[CapturedApp], Never> {
        $runningApps.eraseToAnyPublisher()
    }

    var selectedAppPublisher: AnyPublisher<CapturedApp?, Never> {
        $selectedApp.eraseToAnyPublisher()
    }

    private let runningApplicationProvider: RunningApplicationProviding
    private let userDefaults: UserDefaults
    private let selectedAppBundleIDKey = "selectedAppBundleID"
    private var isApplyingSelection = false

    init(
        runningApplicationProvider: RunningApplicationProviding = NSWorkspaceRunningApplicationProvider(),
        userDefaults: UserDefaults = .standard
    ) {
        self.runningApplicationProvider = runningApplicationProvider
        self.userDefaults = userDefaults

        refreshRunningApps()
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
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

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
