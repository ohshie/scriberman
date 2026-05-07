import Foundation
import Testing
@testable import Scriberman

@MainActor
struct ScreenCaptureServiceTests {
    @Test
    func testRefreshAutoSelectsSingleDisplay() async {
        let userDefaults = makeUserDefaults()
        let display = CaptureDisplay(displayID: 41, name: "Display 1", width: 1728, height: 1117)
        let service = ScreenCaptureService(
            userDefaults: userDefaults,
            displayProvider: { [display] }
        )

        await service.refreshAvailableDisplays()

        #expect(service.availableDisplays == [display])
        #expect(service.selectedDisplayID == 41)
    }

    @Test
    func testRefreshRestoresSavedDisplaySelection() async {
        let userDefaults = makeUserDefaults()
        let displays = [
            CaptureDisplay(displayID: 1, name: "Display 1", width: 2560, height: 1440),
            CaptureDisplay(displayID: 2, name: "Display 2", width: 1920, height: 1080)
        ]
        userDefaults.set(2, forKey: "selectedScreenDisplayID")
        let service = ScreenCaptureService(
            userDefaults: userDefaults,
            displayProvider: { displays }
        )

        await service.refreshAvailableDisplays()

        #expect(service.selectedDisplayID == 2)
    }

    @Test
    func testSelectedDisplayPersistsToUserDefaults() async {
        let userDefaults = makeUserDefaults()
        let displays = [
            CaptureDisplay(displayID: 7, name: "Display 1", width: 1512, height: 982),
            CaptureDisplay(displayID: 8, name: "Display 2", width: 1728, height: 1117)
        ]
        let service = ScreenCaptureService(
            userDefaults: userDefaults,
            displayProvider: { displays }
        )

        await service.refreshAvailableDisplays()
        service.selectedDisplayID = 8

        #expect(userDefaults.integer(forKey: "selectedScreenDisplayID") == 8)
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "ScreenCaptureServiceTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }
}
