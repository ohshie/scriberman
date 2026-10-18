import Foundation
import Testing
@testable import Scriberman

struct AudioSyncConfigTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AudioSyncConfigTests-\(UUID().uuidString)")!
    }

    @Test("An empty store reads every flag as on")
    func unsetFlagsReadOn() {
        let config = AudioSyncConfig(store: makeDefaults())
        #expect(config.isTimelineMixdownEnabled)
        #expect(config.isUnifiedCaptureEnabled)
        #expect(config.isCaptureHealthRecoveryEnabled)
    }

    @Test("A stored value overrides the default")
    func storedValueOverrides() {
        let defaults = makeDefaults()
        let shipped = AudioSyncConfig.FlagDefinitions.shipped
        defaults.set(false, forKey: shipped.timelineMixdown.key)
        defaults.set(false, forKey: shipped.unifiedCapture.key)
        defaults.set(false, forKey: shipped.captureHealthRecovery.key)

        let config = AudioSyncConfig(store: defaults)
        #expect(!config.isTimelineMixdownEnabled)
        #expect(!config.isUnifiedCaptureEnabled)
        #expect(!config.isCaptureHealthRecoveryEnabled)
    }

    @Test("Different flag definitions change the default read from the same store")
    func definitionsChangeDefault() {
        let defaults = makeDefaults()
        var definitions = AudioSyncConfig.FlagDefinitions.shipped
        definitions.timelineMixdown = AudioSyncConfig.Flag(key: definitions.timelineMixdown.key, defaultValue: false)
        definitions.unifiedCapture = AudioSyncConfig.Flag(key: definitions.unifiedCapture.key, defaultValue: false)
        definitions.captureHealthRecovery = AudioSyncConfig.Flag(key: definitions.captureHealthRecovery.key, defaultValue: false)

        let shippedConfig = AudioSyncConfig(store: defaults)
        let changedConfig = AudioSyncConfig(store: defaults, definitions: definitions)

        #expect(shippedConfig.isTimelineMixdownEnabled)
        #expect(!changedConfig.isTimelineMixdownEnabled)
        #expect(shippedConfig.isUnifiedCaptureEnabled)
        #expect(!changedConfig.isUnifiedCaptureEnabled)
        #expect(shippedConfig.isCaptureHealthRecoveryEnabled)
        #expect(!changedConfig.isCaptureHealthRecoveryEnabled)
    }

    @Test("Shipped definitions keep the existing defaults-write keys")
    func shippedKeysAreUnchanged() {
        let shipped = AudioSyncConfig.FlagDefinitions.shipped
        #expect(shipped.timelineMixdown.key == "AudioSync.timelineMixdownEnabled")
        #expect(shipped.unifiedCapture.key == "AudioSync.unifiedCaptureEnabled")
        #expect(shipped.captureHealthRecovery.key == "AudioSync.captureHealthRecoveryEnabled")
    }
}
