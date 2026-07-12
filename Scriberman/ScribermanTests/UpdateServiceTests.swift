import Foundation
import Testing
@testable import Scriberman

@MainActor
struct UpdateServiceTests {
    @Test
    func productionConfigurationRequiresHTTPSFeedPublicKeyAndInstallerLauncher() throws {
        let configuration = try #require(UpdateConfiguration.resolve(
            bundleIdentifier: UpdateConfiguration.productionBundleIdentifier,
            infoDictionary: [
                "SUFeedURL": "https://ohshie.github.io/scriberman/appcast.xml",
                "SUPublicEDKey": "public-key",
                "SUEnableInstallerLauncherService": true,
            ]
        ))

        #expect(configuration.feedURL.absoluteString == "https://ohshie.github.io/scriberman/appcast.xml")
        #expect(configuration.publicEDKey == "public-key")
    }

    @Test
    func debugBundleCannotUseProductionFeed() {
        let configuration = UpdateConfiguration.resolve(
            bundleIdentifier: "com.ohshie.scriberman-dev.app",
            infoDictionary: [
                "SUFeedURL": "https://ohshie.github.io/scriberman/appcast.xml",
                "SUPublicEDKey": "public-key",
                "SUEnableInstallerLauncherService": true,
            ]
        )

        #expect(configuration == nil)
    }

    @Test
    func incompleteOrInsecureConfigurationDisablesUpdater() {
        let base: [String: Any] = [
            "SUFeedURL": "https://ohshie.github.io/scriberman/appcast.xml",
            "SUPublicEDKey": "public-key",
            "SUEnableInstallerLauncherService": true,
        ]

        var missingKey = base
        missingKey["SUPublicEDKey"] = ""
        var insecureFeed = base
        insecureFeed["SUFeedURL"] = "http://ohshie.github.io/scriberman/appcast.xml"
        var missingLauncher = base
        missingLauncher["SUEnableInstallerLauncherService"] = false

        #expect(UpdateConfiguration.resolve(
            bundleIdentifier: UpdateConfiguration.productionBundleIdentifier,
            infoDictionary: missingKey
        ) == nil)
        #expect(UpdateConfiguration.resolve(
            bundleIdentifier: UpdateConfiguration.productionBundleIdentifier,
            infoDictionary: insecureFeed
        ) == nil)
        #expect(UpdateConfiguration.resolve(
            bundleIdentifier: UpdateConfiguration.productionBundleIdentifier,
            infoDictionary: missingLauncher
        ) == nil)
    }

    @Test
    func manualCheckUsesInjectedEngineWhenAvailable() {
        let engine = MockUpdateEngine()
        let service = UpdateService(engine: engine, shortVersion: "1.2.0", buildVersion: "12")

        service.checkForUpdates()

        #expect(engine.checkCount == 1)
        #expect(service.errorMessage == nil)
        #expect(service.canCheckForUpdates)
    }

    @Test
    func unavailableEngineProducesRecoverableState() {
        let service = UpdateService(engine: nil, shortVersion: "1.2.0", buildVersion: "12")

        service.checkForUpdates()

        #expect(!service.isConfigured)
        #expect(!service.canCheckForUpdates)
        #expect(service.errorMessage == "Update checks are unavailable in this build.")
    }

    @Test
    func inProgressEngineDoesNotStartSecondCheck() {
        let engine = MockUpdateEngine()
        engine.canCheckForUpdates = false
        let service = UpdateService(engine: engine, shortVersion: "1.2.0", buildVersion: "12")

        service.checkForUpdates()

        #expect(engine.checkCount == 0)
        #expect(service.errorMessage == "An update check is already in progress.")
    }

    @Test
    func automaticCheckToggleIsPersistedByInjectedEngine() {
        let engine = MockUpdateEngine()
        let service = UpdateService(engine: engine, shortVersion: "1.2.0", buildVersion: "12")

        service.automaticallyChecksForUpdates = true

        #expect(engine.automaticallyChecksForUpdates)
        #expect(service.automaticallyChecksForUpdates)
        #expect(service.errorMessage == nil)
    }

    @Test
    func currentVersionTextIncludesShortAndBuildVersions() {
        let service = UpdateService(engine: nil, shortVersion: "2.3.4", buildVersion: "57")

        #expect(service.currentVersionText == "Version 2.3.4 (57)")
    }
}

@MainActor
private final class MockUpdateEngine: UpdateEngine {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    private(set) var checkCount = 0

    func checkForUpdates() {
        checkCount += 1
    }
}
