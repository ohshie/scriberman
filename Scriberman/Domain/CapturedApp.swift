import AppKit
import Foundation

struct CapturedApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let pid: pid_t
    let icon: NSImage?

    var id: String {
        bundleID
    }

    static func == (lhs: CapturedApp, rhs: CapturedApp) -> Bool {
        lhs.bundleID == rhs.bundleID
            && lhs.name == rhs.name
            && lhs.pid == rhs.pid
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
        hasher.combine(name)
        hasher.combine(pid)
    }
}
