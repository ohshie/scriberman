import CoreGraphics
import Foundation

struct CaptureDisplay: Identifiable, Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int

    var id: CGDirectDisplayID { displayID }

    var resolutionLabel: String {
        "\(width)×\(height)"
    }
}

@MainActor
protocol ScreenCaptureServiceProtocol: AnyObject {
    var availableDisplays: [CaptureDisplay] { get }
    var selectedDisplayID: CGDirectDisplayID? { get set }
    func refreshAvailableDisplays() async
}
