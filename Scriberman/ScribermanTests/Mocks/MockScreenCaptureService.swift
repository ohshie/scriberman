import CoreGraphics
import Foundation
@testable import Scriberman

@MainActor
final class MockScreenCaptureService: ScreenCaptureServiceProtocol {
    var availableDisplays: [CaptureDisplay] = []
    var selectedDisplayID: CGDirectDisplayID?
    var refreshCalls = 0

    func refreshAvailableDisplays() async {
        refreshCalls += 1
    }
}
