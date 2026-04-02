import Foundation

@MainActor
protocol AppAudioServiceProtocol: AnyObject {
    var runningApps: [CapturedApp] { get }
    var selectedApp: CapturedApp? { get set }
    func incrementUsage(for bundleID: String)
    func refreshRunningApps()
}
