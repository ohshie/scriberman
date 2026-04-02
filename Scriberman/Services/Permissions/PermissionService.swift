import AVFoundation
import Foundation
import Observation
import OSLog

enum PermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied
}

@MainActor
@Observable
final class PermissionService: PermissionServiceProtocol {
    enum DefaultsKey {
        static let screenRecordingPromptHasBeenShown = "screenRecordingPromptHasBeenShown"
        static let permissionsOnboardingHasBeenShown = "permissionsOnboardingHasBeenShown"
    }

    private(set) var micStatus: PermissionStatus = .notDetermined
    private(set) var screenRecordingStatus: PermissionStatus = .notDetermined

    var needsOnboarding: Bool {
        let hasShownOnboarding = userDefaults.bool(forKey: DefaultsKey.permissionsOnboardingHasBeenShown)
        let hasUnverifiedPermission = micStatus != .granted || screenRecordingStatus != .granted
        return !hasShownOnboarding && hasUnverifiedPermission
    }

    private let microphonePermissions: MicrophonePermissionProviding
    private let screenRecordingPermissions: ScreenRecordingPermissionProviding
    private let screenRecordingFunctionalPermissions: ScreenRecordingFunctionalPermissionProviding
    private let userDefaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let logger = Logger(subsystem: "Scriberman", category: "PermissionService")
    // nonisolated(unsafe): written once in init, removed in deinit; never mutated concurrently
    nonisolated(unsafe) private var appAudioCaptureAccessDeniedObserver: NSObjectProtocol?

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
        self.notificationCenter = notificationCenter

        appAudioCaptureAccessDeniedObserver = notificationCenter.addObserver(
            forName: .appAudioCaptureAccessDenied,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAppAudioCaptureAccessDenied(notification)
            }
        }

        checkAll()
    }

    deinit {
        if let appAudioCaptureAccessDeniedObserver {
            notificationCenter.removeObserver(appAudioCaptureAccessDeniedObserver)
        }
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
            if screenRecordingStatus != .denied {
                screenRecordingStatus = .notDetermined
            }
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
        screenRecordingStatus = granted ? .granted : .denied

        logger.info(
            "[\(self.timestamp(), privacy: .public)] source=requestScreenRecording requestResult=\(granted, privacy: .public) screenStatus=\(self.description(for: self.screenRecordingStatus), privacy: .public)"
        )

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
            if screenRecordingStatus != .denied {
                screenRecordingStatus = .notDetermined
            }

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
