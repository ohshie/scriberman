import Foundation
@testable import Scriberman

@MainActor
final class MockAppAudioService: AppAudioServiceProtocol {
    var runningApps: [CapturedApp] = []
    var selectedApp: CapturedApp?
    var refreshCalls = 0
    var incrementUsageCalls: [String] = []

    func incrementUsage(for bundleID: String) {
        incrementUsageCalls.append(bundleID)
    }

    func refreshRunningApps() {
        refreshCalls += 1
    }
}
