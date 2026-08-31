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
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
}

@MainActor
private final class SparkleUpdateEngine: UpdateEngine {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
@Observable
final class UpdateService {
    @ObservationIgnored private let engine: (any UpdateEngine)?

    let currentVersionText: String
    private(set) var errorMessage: String?

    init(
        engine: (any UpdateEngine)?,
        shortVersion: String,
        buildVersion: String
    ) {
        self.engine = engine
        currentVersionText = "Version \(shortVersion) (\(buildVersion))"
    }

    static func live(bundle: Bundle = .main) -> UpdateService {
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let engine: (any UpdateEngine)? = UpdateConfiguration.resolve(bundle: bundle) == nil
            ? nil
            : SparkleUpdateEngine()

        return UpdateService(
            engine: engine,
            shortVersion: shortVersion,
            buildVersion: buildVersion
        )
    }

    var isConfigured: Bool {
        engine != nil
    }

    var canCheckForUpdates: Bool {
        engine?.canCheckForUpdates ?? false
    }

    var automaticallyChecksForUpdates: Bool {
        get { engine?.automaticallyChecksForUpdates ?? false }
        set {
            guard let engine else {
                errorMessage = "Update checks are unavailable in this build."
                return
            }
            engine.automaticallyChecksForUpdates = newValue
            errorMessage = nil
        }
    }

    func checkForUpdates() {
        guard let engine else {
            errorMessage = "Update checks are unavailable in this build."
            return
        }
        guard engine.canCheckForUpdates else {
            errorMessage = "An update check is already in progress."
            return
        }

        errorMessage = nil
        engine.checkForUpdates()
    }
}
