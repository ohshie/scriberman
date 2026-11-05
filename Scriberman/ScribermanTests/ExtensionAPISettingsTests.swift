import Foundation
import Testing
@testable import Scriberman

@MainActor
struct ExtensionAPISettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ExtensionAPISettingsTests-\(UUID().uuidString)")!
    }

    @Test("Fresh install has the API off on port 47615")
    func defaults() {
        let settings = ExtensionAPISettings(userDefaults: makeDefaults())
        #expect(!settings.isEnabled)
        #expect(settings.port == 47615)
    }

    @Test("Enabled flag and port survive a relaunch")
    func valuesPersist() throws {
        let defaults = makeDefaults()
        let first = ExtensionAPISettings(userDefaults: defaults)
        first.isEnabled = true
        try first.setPort(50000)

        let second = ExtensionAPISettings(userDefaults: defaults)
        #expect(second.isEnabled)
        #expect(second.port == 50000)
    }

    @Test("Ports at both ends of the range are accepted", arguments: [1024, 65535])
    func boundaryPorts(port: Int) throws {
        let settings = ExtensionAPISettings(userDefaults: makeDefaults())
        try settings.setPort(port)
        #expect(settings.port == port)
    }

    @Test("Ports outside 1024 to 65535 are rejected and the port stays", arguments: [0, 80, 1023, 65536, -1])
    func invalidPortRejected(port: Int) throws {
        let defaults = makeDefaults()
        let settings = ExtensionAPISettings(userDefaults: defaults)
        try settings.setPort(50000)
        #expect(throws: ExtensionAPISettings.InvalidPort.self) {
            try settings.setPort(port)
        }
        #expect(settings.port == 50000)
        #expect(ExtensionAPISettings(userDefaults: defaults).port == 50000)
    }

    @Test("An out-of-range stored port reads as the default")
    func invalidStoredPort() {
        let defaults = makeDefaults()
        defaults.set(80, forKey: "extensionAPI.port")
        #expect(ExtensionAPISettings(userDefaults: defaults).port == 47615)
    }
}
