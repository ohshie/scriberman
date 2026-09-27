import Foundation
import Observation
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
        #expect(!service.canCheckForUpdates)
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

        service.setAutomaticallyChecksForUpdates(true)

        #expect(engine.automaticallyChecksForUpdates)
        #expect(service.automaticallyChecksForUpdates)
        #expect(service.errorMessage == nil)
    }

    @Test
    func readinessChangesAsynchronouslyNotifyObservers() async {
        let engine = MockUpdateEngine()
        let service = UpdateService(engine: engine, shortVersion: "1", buildVersion: "1")

        for ready in [false, true] {
            await confirmation("Readiness change is observed") { changed in
                withObservationTracking {
                    _ = service.canCheckForUpdates
                } onChange: {
                    changed()
                }
                await engine.changeReadiness(to: ready)
            }
            #expect(service.canCheckForUpdates == ready)
        }
    }

    @Test
    func activeSessionDisablesChecksEvenWhenSparkleAllowsFocusingItsWindow() {
        let engine = MockUpdateEngine()
        engine.sessionInProgress = true
        let service = UpdateService(engine: engine, shortVersion: "1", buildVersion: "1")

        #expect(engine.canCheckForUpdates)
        #expect(!service.canCheckForUpdates)
        service.checkForUpdates()
        #expect(engine.checkCount == 0)
        #expect(service.errorMessage == "An update check is already in progress.")
    }

    @Test
    func sessionEndNotifiesObserversAndAllowsAnotherCheck() async {
        let engine = MockUpdateEngine()
        let service = UpdateService(engine: engine, shortVersion: "1", buildVersion: "1")

        await confirmation("Starting a check disables the action") { changed in
            withObservationTracking {
                _ = service.canCheckForUpdates
            } onChange: {
                changed()
            }
            service.checkForUpdates()
        }
        #expect(!service.canCheckForUpdates)
        #expect(engine.canCheckForUpdates)
        service.checkForUpdates()
        #expect(engine.checkCount == 1)

        await confirmation("Ending the session enables the action") { changed in
            withObservationTracking {
                _ = service.canCheckForUpdates
            } onChange: {
                changed()
            }
            await engine.changeSessionInProgress(to: false)
        }
        #expect(service.canCheckForUpdates)
        service.checkForUpdates()
        #expect(engine.checkCount == 2)
        #expect(service.errorMessage == nil)
    }

    @Test
    func sessionChangesAsynchronouslyDisableAndEnableChecks() async {
        let engine = MockUpdateEngine()
        let service = UpdateService(engine: engine, shortVersion: "1", buildVersion: "1")

        for inProgress in [true, false] {
            await confirmation("Session change is observed") { changed in
                withObservationTracking {
                    _ = service.canCheckForUpdates
                } onChange: {
                    changed()
                }
                await engine.changeSessionInProgress(to: inProgress)
            }
            #expect(service.canCheckForUpdates == !inProgress)
        }
    }

    @Test
    func externalAutomaticCheckChangesNotifyObservers() async {
        let engine = MockUpdateEngine()
        let service = UpdateService(engine: engine, shortVersion: "1", buildVersion: "1")

        await confirmation("Automatic check change is observed") { changed in
            withObservationTracking {
                _ = service.automaticallyChecksForUpdates
            } onChange: {
                changed()
            }
            engine.automaticallyChecksForUpdates = true
            engine.onStateChange?()
        }
        #expect(service.automaticallyChecksForUpdates)
    }

    @Test
    func automaticCheckSetterNotifiesWithoutEngineCallback() async {
        let engine = MockUpdateEngine()
        let service = UpdateService(engine: engine, shortVersion: "1", buildVersion: "1")

        await confirmation("Automatic check setter is observed") { changed in
            withObservationTracking {
                _ = service.automaticallyChecksForUpdates
            } onChange: {
                changed()
            }
            service.setAutomaticallyChecksForUpdates(true)
        }
        #expect(service.automaticallyChecksForUpdates)
    }

    @Test
    func unavailableEngineRejectsAutomaticChecks() {
        let service = UpdateService(engine: nil, shortVersion: "1", buildVersion: "1")
        service.setAutomaticallyChecksForUpdates(true)
        #expect(!service.automaticallyChecksForUpdates)
        #expect(service.errorMessage == "Update checks are unavailable in this build.")
    }

    @Test
    func engineCallbackDoesNotRetainService() {
        let engine = MockUpdateEngine()
        var service: UpdateService? = UpdateService(engine: engine, shortVersion: "1", buildVersion: "1")
        weak var weakService = service
        service = nil
        #expect(weakService == nil)
        engine.onStateChange?()
    }

    @Test
    func currentVersionTextIncludesShortAndBuildVersions() {
        let service = UpdateService(engine: nil, shortVersion: "2.3.4", buildVersion: "57")

        #expect(service.currentVersionText == "Version 2.3.4 (57)")
    }
}

@MainActor
private final class MockUpdateEngine: UpdateEngine {
    var onStateChange: (() -> Void)?
    var canCheckForUpdates = true
    var sessionInProgress = false
    var automaticallyChecksForUpdates = false
    private(set) var checkCount = 0

    func changeReadiness(to ready: Bool) async {
        await Task.yield()
        canCheckForUpdates = ready
        onStateChange?()
    }

    func changeSessionInProgress(to inProgress: Bool) async {
        await Task.yield()
        sessionInProgress = inProgress
        onStateChange?()
    }

    func checkForUpdates() {
        checkCount += 1
        sessionInProgress = true
    }
}
