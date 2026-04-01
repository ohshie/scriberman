import Foundation

@MainActor
protocol PermissionServiceProtocol: AnyObject {
    var micStatus: PermissionStatus { get }
    var screenRecordingStatus: PermissionStatus { get }
    var needsOnboarding: Bool { get }
    func checkAll()
    func requestMic() async -> Bool
    func requestScreenRecording() -> Bool
    func verifyMic() async -> Bool
    func verifyScreenRecording() async -> Bool
    func markOnboardingShown()
}
