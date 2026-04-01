import AppKit
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
