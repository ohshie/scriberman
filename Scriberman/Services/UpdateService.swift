import Foundation
import Observation
import Sparkle

struct UpdateConfiguration: Equatable {
    static let productionBundleIdentifier = "com.ohshie.scriberman.app"

    let feedURL: URL
    let publicEDKey: String

    static func resolve(
        bundleIdentifier: String?,
        infoDictionary: [String: Any]?
    ) -> UpdateConfiguration? {
        guard bundleIdentifier == productionBundleIdentifier,
              let feedURLString = infoDictionary?["SUFeedURL"] as? String,
              let feedURL = URL(string: feedURLString),
              feedURL.scheme == "https",
              feedURL.host != nil,
              let publicEDKey = infoDictionary?["SUPublicEDKey"] as? String,
              !publicEDKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              infoDictionary?["SUEnableInstallerLauncherService"] as? Bool == true else {
            return nil
        }

        return UpdateConfiguration(feedURL: feedURL, publicEDKey: publicEDKey)
    }

    static func resolve(bundle: Bundle) -> UpdateConfiguration? {
        resolve(bundleIdentifier: bundle.bundleIdentifier, infoDictionary: bundle.infoDictionary)
    }
}

@MainActor
protocol UpdateEngine: AnyObject {
    var onStateChange: (() -> Void)? { get set }
    var canCheckForUpdates: Bool { get }
    var sessionInProgress: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    /// Appcast channels offered besides the default channel. Empty offers stable releases only.
    var allowedChannels: Set<String> { get set }
    func checkForUpdates()
}

/// Answers Sparkle's channel query. Sparkle calls it on the main thread.
private final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    nonisolated(unsafe) var allowedChannels: Set<String>

    init(allowedChannels: Set<String>) {
        self.allowedChannels = allowedChannels
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowedChannels
    }
}

@MainActor
private final class SparkleUpdateEngine: UpdateEngine {
    private let controller: SPUStandardUpdaterController
    /// Retained here because the controller holds its updater delegate weakly.
    private let delegate: SparkleUpdaterDelegate
    private var observations: [NSKeyValueObservation] = []
    var onStateChange: (() -> Void)?

    /// The channels are in place before the updater starts, so its first scheduled check uses them.
    init(allowedChannels: Set<String>) {
        delegate = SparkleUpdaterDelegate(allowedChannels: allowedChannels)
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        observations = [
            controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.onStateChange?() }
            },
            controller.updater.observe(\.sessionInProgress) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.onStateChange?() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.onStateChange?() }
            },
        ]
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var sessionInProgress: Bool {
        controller.updater.sessionInProgress
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var allowedChannels: Set<String> {
        get { delegate.allowedChannels }
        set { delegate.allowedChannels = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
@Observable
final class UpdateService {
    static let betaChannel = "beta"

    @ObservationIgnored private let engine: (any UpdateEngine)?

    private(set) var canCheckForUpdates: Bool
    private(set) var automaticallyChecksForUpdates: Bool

    let currentVersionText: String
    private(set) var errorMessage: String?

    convenience init(
        engine: (any UpdateEngine)?,
        shortVersion: String,
        buildVersion: String
    ) {
        self.init(
            engineFactory: engine.map { engine in { _ in engine } },
            betaBuildsEnabled: false,
            shortVersion: shortVersion,
            buildVersion: buildVersion
        )
    }

    /// `engineFactory` receives the allowed channels for the stored beta opt-in. Creating the
    /// engine starts no check.
    init(
        engineFactory: ((Set<String>) -> any UpdateEngine)?,
        betaBuildsEnabled: Bool,
        shortVersion: String,
        buildVersion: String
    ) {
        let engine = engineFactory?(Self.allowedChannels(betaBuildsEnabled: betaBuildsEnabled))
        self.engine = engine
        canCheckForUpdates = engine.map { $0.canCheckForUpdates && !$0.sessionInProgress } ?? false
        automaticallyChecksForUpdates = engine?.automaticallyChecksForUpdates ?? false
        currentVersionText = "Version \(shortVersion) (\(buildVersion))"
        engine?.onStateChange = { [weak self] in
            self?.refreshState()
        }
    }

    static func live(bundle: Bundle = .main, developerSettings: DeveloperSettings) -> UpdateService {
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let engineFactory: ((Set<String>) -> any UpdateEngine)? = UpdateConfiguration.resolve(bundle: bundle) == nil
            ? nil
            : { SparkleUpdateEngine(allowedChannels: $0) }

        return UpdateService(
            engineFactory: engineFactory,
            betaBuildsEnabled: developerSettings.betaBuildsEnabled,
            shortVersion: shortVersion,
            buildVersion: buildVersion
        )
    }

    var isConfigured: Bool {
        engine != nil
    }

    private static func allowedChannels(betaBuildsEnabled: Bool) -> Set<String> {
        betaBuildsEnabled ? [betaChannel] : []
    }

    private func refreshState() {
        // Sparkle permits focusing its UI during a session; our action starts a new check.
        canCheckForUpdates = engine.map { $0.canCheckForUpdates && !$0.sessionInProgress } ?? false
        automaticallyChecksForUpdates = engine?.automaticallyChecksForUpdates ?? false
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let engine else {
            errorMessage = "Update checks are unavailable in this build."
            return
        }
        engine.automaticallyChecksForUpdates = enabled
        refreshState()
        errorMessage = nil
    }

    func checkForUpdates() {
        guard let engine else {
            errorMessage = "Update checks are unavailable in this build."
            return
        }
        guard engine.canCheckForUpdates && !engine.sessionInProgress else {
            errorMessage = "An update check is already in progress."
            return
        }

        errorMessage = nil
        engine.checkForUpdates()
        refreshState()
    }

    /// Stores the opt-in and applies it to the updater. Turning beta on starts one check when the
    /// updater is idle; otherwise the next scheduled or manual check uses the beta channel.
    /// Turning it off starts no check. Without an engine only the stored value changes.
    func setBetaBuilds(_ enabled: Bool, in settings: DeveloperSettings) {
        settings.setBetaBuilds(enabled)
        guard let engine else { return }

        let channels = Self.allowedChannels(betaBuildsEnabled: enabled)
        guard engine.allowedChannels != channels else { return }
        engine.allowedChannels = channels

        if enabled && engine.canCheckForUpdates && !engine.sessionInProgress {
            checkForUpdates()
        }
    }
}
