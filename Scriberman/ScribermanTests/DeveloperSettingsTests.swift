import Foundation
import Testing
@testable import Scriberman

@MainActor
struct DeveloperSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DeveloperSettingsTests-\(UUID().uuidString)")!
    }

    private func click(_ settings: DeveloperSettings, times: Int) {
        for _ in 0..<times {
            settings.registerVersionClick()
        }
    }

    private var shipped: AudioSyncConfig.FlagDefinitions { .shipped }

    @Test("Fresh install is locked and every flag reads its default")
    func freshInstall() {
        let settings = DeveloperSettings(store: makeDefaults())
        #expect(!settings.isUnlocked)
        for flag in settings.flags {
            #expect(settings.isOn(flag) == flag.defaultValue)
        }
    }

    @Test("Flags are listed from their definitions")
    func flagsComeFromDefinitions() {
        let settings = DeveloperSettings(store: makeDefaults())
        #expect(settings.flags == [shipped.timelineMixdown, shipped.unifiedCapture, shipped.captureHealthRecovery])
    }

    @Test("Seven clicks on the version label unlock")
    func sevenClicksUnlock() {
        let settings = DeveloperSettings(store: makeDefaults())
        click(settings, times: 7)
        #expect(settings.isUnlocked)
    }

    @Test("Six clicks on the version label do not unlock")
    func sixClicksDoNotUnlock() {
        let settings = DeveloperSettings(store: makeDefaults())
        click(settings, times: 6)
        #expect(!settings.isUnlocked)
    }

    @Test("Closing Settings resets the click count")
    func closingSettingsResetsCount() {
        let settings = DeveloperSettings(store: makeDefaults())
        click(settings, times: 6)
        settings.settingsDidClose()
        click(settings, times: 6)
        #expect(!settings.isUnlocked)
        click(settings, times: 1)
        #expect(settings.isUnlocked)
    }

    @Test("Unlocking again after hide needs seven fresh clicks")
    func hideNeedsSevenFreshClicks() {
        let settings = DeveloperSettings(store: makeDefaults())
        click(settings, times: 7)
        settings.hide()
        #expect(!settings.isUnlocked)
        click(settings, times: 6)
        #expect(!settings.isUnlocked)
        click(settings, times: 1)
        #expect(settings.isUnlocked)
    }

    @Test("Unlocked state persists across relaunch")
    func unlockedPersists() {
        let defaults = makeDefaults()
        let first = DeveloperSettings(store: defaults)
        click(first, times: 7)
        #expect(DeveloperSettings(store: defaults).isUnlocked)

        first.hide()
        #expect(!DeveloperSettings(store: defaults).isUnlocked)
    }

    @Test("Hide keeps every flag value")
    func hideKeepsFlags() {
        let defaults = makeDefaults()
        let settings = DeveloperSettings(store: defaults)
        click(settings, times: 7)
        for flag in settings.flags {
            settings.set(flag, isOn: !flag.defaultValue)
        }
        settings.hide()

        for flag in settings.flags {
            #expect(settings.isOn(flag) == !flag.defaultValue)
        }
        let relaunched = DeveloperSettings(store: defaults)
        for flag in relaunched.flags {
            #expect(relaunched.isOn(flag) == !flag.defaultValue)
        }
    }

    @Test("Beta builds are off on a fresh install and persist across relaunch")
    func betaBuildsPersist() {
        let defaults = makeDefaults()
        #expect(!DeveloperSettings(store: defaults).betaBuildsEnabled)

        DeveloperSettings(store: defaults).setBetaBuilds(true)
        #expect(DeveloperSettings(store: defaults).betaBuildsEnabled)

        DeveloperSettings(store: defaults).setBetaBuilds(false)
        #expect(!DeveloperSettings(store: defaults).betaBuildsEnabled)
    }

    @Test("Hide keeps the beta builds opt-in")
    func hideKeepsBetaBuilds() {
        let defaults = makeDefaults()
        let settings = DeveloperSettings(store: defaults)
        click(settings, times: 7)
        settings.setBetaBuilds(true)
        settings.hide()

        #expect(settings.betaBuildsEnabled)
        #expect(DeveloperSettings(store: defaults).betaBuildsEnabled)
    }

    @Test("A flag set away from its default persists across relaunch")
    func flagAwayFromDefaultPersists() {
        let defaults = makeDefaults()
        let flag = shipped.unifiedCapture
        DeveloperSettings(store: defaults).set(flag, isOn: !flag.defaultValue)
        #expect(DeveloperSettings(store: defaults).isOn(flag) == !flag.defaultValue)
    }

    @Test("A flag set back to its default follows a changed default after relaunch")
    func flagBackAtDefaultFollowsNewDefault() {
        let defaults = makeDefaults()
        let flag = shipped.timelineMixdown
        let first = DeveloperSettings(store: defaults)
        first.set(flag, isOn: !flag.defaultValue)
        first.set(flag, isOn: flag.defaultValue)

        var changed = shipped
        changed.timelineMixdown = AudioSyncConfig.Flag(key: flag.key, defaultValue: !flag.defaultValue)
        let relaunched = DeveloperSettings(store: defaults, flagDefinitions: changed)
        #expect(relaunched.isOn(changed.timelineMixdown) == !flag.defaultValue)
    }

    @Test("A value already in the store shows as the flag's value")
    func existingOverrideShows() {
        let defaults = makeDefaults()
        let flag = shipped.captureHealthRecovery
        defaults.set(!flag.defaultValue, forKey: flag.key)
        #expect(DeveloperSettings(store: defaults).isOn(flag) == !flag.defaultValue)
    }

    @Test("A toggle through the model is what the audio-sync config reads from the same store")
    func toggleReachesAudioSyncConfig() {
        let defaults = makeDefaults()
        let settings = DeveloperSettings(store: defaults)
        let config = AudioSyncConfig(store: defaults)

        settings.set(shipped.timelineMixdown, isOn: false)
        settings.set(shipped.unifiedCapture, isOn: false)
        settings.set(shipped.captureHealthRecovery, isOn: false)
        #expect(config.snapshot() == AudioSyncFlags(
            isTimelineMixdownEnabled: false,
            isUnifiedCaptureEnabled: false,
            isCaptureHealthRecoveryEnabled: false
        ))

        settings.set(shipped.unifiedCapture, isOn: true)
        #expect(config.isUnifiedCaptureEnabled)
    }
}
