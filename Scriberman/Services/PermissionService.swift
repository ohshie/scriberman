import AVFoundation
import Combine
import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit

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

struct ScreenRecordingShareableContentSnapshot {
    let windowCount: Int
    let applicationCount: Int

    var hasVisibleContent: Bool {
        windowCount > 0 || applicationCount > 0
    }
}

protocol ScreenRecordingFunctionalPermissionProviding {
    func shareableContentSnapshot() async throws -> ScreenRecordingShareableContentSnapshot
}

struct ScreenCaptureKitFunctionalPermissionProvider: ScreenRecordingFunctionalPermissionProviding {
    func shareableContentSnapshot() async throws -> ScreenRecordingShareableContentSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return ScreenRecordingShareableContentSnapshot(
            windowCount: content.windows.count,
            applicationCount: content.applications.count
        )
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
    func verifyMic() async -> Bool
    func verifyScreenRecording() async -> Bool
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
        let hasUnverifiedPermission = micStatus != .granted || screenRecordingStatus != .granted
        return !hasShownOnboarding && hasUnverifiedPermission
    }

    private let microphonePermissions: MicrophonePermissionProviding
    private let screenRecordingPermissions: ScreenRecordingPermissionProviding
    private let screenRecordingFunctionalPermissions: ScreenRecordingFunctionalPermissionProviding
    private let userDefaults: UserDefaults
    private let logger = Logger(subsystem: "Scriberman", category: "PermissionService")
    private var cancellables = Set<AnyCancellable>()

    init(
        microphonePermissions: MicrophonePermissionProviding = AVCaptureMicrophonePermissionProvider(),
        screenRecordingPermissions: ScreenRecordingPermissionProviding = CoreGraphicsScreenRecordingPermissionProvider(),
        screenRecordingFunctionalPermissions: ScreenRecordingFunctionalPermissionProviding = ScreenCaptureKitFunctionalPermissionProvider(),
        userDefaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.microphonePermissions = microphonePermissions
        self.screenRecordingPermissions = screenRecordingPermissions
        self.screenRecordingFunctionalPermissions = screenRecordingFunctionalPermissions
        self.userDefaults = userDefaults

        notificationCenter
            .publisher(for: .appAudioCaptureAccessDenied)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleAppAudioCaptureAccessDenied(notification)
                }
            }
            .store(in: &cancellables)

        checkAll()
    }

    func checkAll() {
        let authorizationStatus = microphonePermissions.authorizationStatus()
        micStatus = mapMicrophoneStatus(authorizationStatus)
        let preflightGranted = screenRecordingPermissions.preflightAccess()

        if preflightGranted {
            if screenRecordingStatus != .denied {
                screenRecordingStatus = .granted
            }
        } else {
            let hasShownPrompt = userDefaults.bool(forKey: DefaultsKey.screenRecordingPromptHasBeenShown)
            screenRecordingStatus = hasShownPrompt ? .denied : .notDetermined
        }

        logger.info(
            "[\(self.timestamp(), privacy: .public)] source=checkAll micAuthStatus=\(authorizationStatus.rawValue, privacy: .public) micStatus=\(self.description(for: self.micStatus), privacy: .public) screenPreflight=\(preflightGranted, privacy: .public) screenStatus=\(self.description(for: self.screenRecordingStatus), privacy: .public)"
        )
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

    func verifyMic() async -> Bool {
        let authorizationStatus = microphonePermissions.authorizationStatus()
        micStatus = mapMicrophoneStatus(authorizationStatus)

        logger.info(
            "[\(self.timestamp(), privacy: .public)] source=verifyMic micAuthStatus=\(authorizationStatus.rawValue, privacy: .public) micStatus=\(self.description(for: self.micStatus), privacy: .public)"
        )

        return micStatus == .granted
    }

    func verifyScreenRecording() async -> Bool {
        let preflightGranted = screenRecordingPermissions.preflightAccess()

        guard preflightGranted else {
            let hasShownPrompt = userDefaults.bool(forKey: DefaultsKey.screenRecordingPromptHasBeenShown)
            screenRecordingStatus = hasShownPrompt ? .denied : .notDetermined

            logger.info(
                "[\(self.timestamp(), privacy: .public)] source=verifyScreenRecording screenPreflight=\(preflightGranted, privacy: .public) functional=false windowCount=0 appCount=0 screenStatus=\(self.description(for: self.screenRecordingStatus), privacy: .public)"
            )
            return false
        }

        do {
            let snapshot = try await screenRecordingFunctionalPermissions.shareableContentSnapshot()
            let functional = snapshot.hasVisibleContent
            screenRecordingStatus = functional ? .granted : .denied

            logger.info(
                "[\(self.timestamp(), privacy: .public)] source=verifyScreenRecording screenPreflight=\(preflightGranted, privacy: .public) functional=\(functional, privacy: .public) windowCount=\(snapshot.windowCount, privacy: .public) appCount=\(snapshot.applicationCount, privacy: .public) screenStatus=\(self.description(for: self.screenRecordingStatus), privacy: .public)"
            )
            return functional
        } catch {
            screenRecordingStatus = .denied
            logger.error(
                "[\(self.timestamp(), privacy: .public)] source=verifyScreenRecording screenPreflight=\(preflightGranted, privacy: .public) functional=false screenStatus=\(self.description(for: self.screenRecordingStatus), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
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

    private func handleAppAudioCaptureAccessDenied(_ notification: Notification) {
        userDefaults.set(true, forKey: DefaultsKey.screenRecordingPromptHasBeenShown)
        screenRecordingStatus = .denied
        let errorDescription = notification.userInfo?["errorDescription"] as? String ?? "unknown"
        logger.error(
            "[\(self.timestamp(), privacy: .public)] source=streamDelegate screenStatus=\(self.description(for: self.screenRecordingStatus), privacy: .public) error=\(errorDescription, privacy: .public)"
        )
    }

    private func description(for status: PermissionStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        }
    }

    private func timestamp(date: Date = .now) -> String {
        date.ISO8601Format()
    }
}
