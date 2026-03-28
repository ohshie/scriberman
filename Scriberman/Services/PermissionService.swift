import AVFoundation
import Combine
import CoreGraphics
import Foundation

enum PermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied
}

protocol MicrophonePermissionProviding {
    func authorizationStatus() -> AVAuthorizationStatus
    func requestAccess() async -> Bool
}

struct AVCaptureMicrophonePermissionProvider: MicrophonePermissionProviding {
    func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

protocol ScreenRecordingPermissionProviding {
    func preflightAccess() -> Bool
    func requestAccess() -> Bool
}

struct CoreGraphicsScreenRecordingPermissionProvider: ScreenRecordingPermissionProviding {
    func preflightAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

@MainActor
protocol PermissionServiceProtocol: AnyObject {
    var micStatus: PermissionStatus { get }
    var screenRecordingStatus: PermissionStatus { get }
    var micStatusPublisher: AnyPublisher<PermissionStatus, Never> { get }
    var screenRecordingStatusPublisher: AnyPublisher<PermissionStatus, Never> { get }
    var needsOnboarding: Bool { get }
    func checkAll()
    func requestMic() async -> Bool
    func requestScreenRecording() -> Bool
    func markOnboardingShown()
}

@MainActor
final class PermissionService: ObservableObject, PermissionServiceProtocol {
    enum DefaultsKey {
        static let screenRecordingPromptHasBeenShown = "screenRecordingPromptHasBeenShown"
        static let permissionsOnboardingHasBeenShown = "permissionsOnboardingHasBeenShown"
    }

    @Published private(set) var micStatus: PermissionStatus = .notDetermined
    @Published private(set) var screenRecordingStatus: PermissionStatus = .notDetermined

    var micStatusPublisher: AnyPublisher<PermissionStatus, Never> {
        $micStatus.eraseToAnyPublisher()
    }

    var screenRecordingStatusPublisher: AnyPublisher<PermissionStatus, Never> {
        $screenRecordingStatus.eraseToAnyPublisher()
    }

    var needsOnboarding: Bool {
        let hasShownOnboarding = userDefaults.bool(forKey: DefaultsKey.permissionsOnboardingHasBeenShown)
        let hasUndeterminedPermission = micStatus == .notDetermined || screenRecordingStatus == .notDetermined
        return !hasShownOnboarding && hasUndeterminedPermission
    }

    private let microphonePermissions: MicrophonePermissionProviding
    private let screenRecordingPermissions: ScreenRecordingPermissionProviding
    private let userDefaults: UserDefaults

    init(
        microphonePermissions: MicrophonePermissionProviding = AVCaptureMicrophonePermissionProvider(),
        screenRecordingPermissions: ScreenRecordingPermissionProviding = CoreGraphicsScreenRecordingPermissionProvider(),
        userDefaults: UserDefaults = .standard
    ) {
        self.microphonePermissions = microphonePermissions
        self.screenRecordingPermissions = screenRecordingPermissions
        self.userDefaults = userDefaults
        checkAll()
    }

    func checkAll() {
        micStatus = mapMicrophoneStatus(microphonePermissions.authorizationStatus())

        if screenRecordingPermissions.preflightAccess() {
            screenRecordingStatus = .granted
        } else {
            let hasShownPrompt = userDefaults.bool(forKey: DefaultsKey.screenRecordingPromptHasBeenShown)
            screenRecordingStatus = hasShownPrompt ? .denied : .notDetermined
        }
    }

    func requestMic() async -> Bool {
        let granted = await microphonePermissions.requestAccess()
        checkAll()
        return granted
    }

    func requestScreenRecording() -> Bool {
        let granted = screenRecordingPermissions.requestAccess()
        userDefaults.set(true, forKey: DefaultsKey.screenRecordingPromptHasBeenShown)
        checkAll()
        return granted
    }

    func markOnboardingShown() {
        userDefaults.set(true, forKey: DefaultsKey.permissionsOnboardingHasBeenShown)
        checkAll()
    }

    private func mapMicrophoneStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .granted
        default:
            return .denied
        }
    }
}
