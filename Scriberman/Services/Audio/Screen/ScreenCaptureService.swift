import Foundation
import Observation
import ScreenCaptureKit

@MainActor
@Observable
final class ScreenCaptureService: ScreenCaptureServiceProtocol {
    typealias DisplayProvider = @Sendable () async throws -> [CaptureDisplay]

    var availableDisplays: [CaptureDisplay] = []
    var selectedDisplayID: CGDirectDisplayID? {
        didSet {
            guard !isApplyingSelection else {
                return
            }
            persistSelectedDisplayID()
        }
    }

    private let userDefaults: UserDefaults
    private let displayProvider: DisplayProvider
    private let selectedDisplayIDKey = "selectedScreenDisplayID"
    private var isApplyingSelection = false

    init(
        userDefaults: UserDefaults = .standard,
        displayProvider: DisplayProvider? = nil
    ) {
        self.userDefaults = userDefaults
        self.displayProvider = displayProvider ?? Self.defaultDisplayProvider
    }

    func refreshAvailableDisplays() async {
        do {
            availableDisplays = try await displayProvider()
        } catch {
            availableDisplays = []
        }

        revalidateSelectedDisplay()
    }

    private func persistSelectedDisplayID() {
        if let selectedDisplayID {
            userDefaults.set(Int(selectedDisplayID), forKey: selectedDisplayIDKey)
        } else {
            userDefaults.removeObject(forKey: selectedDisplayIDKey)
        }
    }

    private func revalidateSelectedDisplay() {
        if let selectedDisplayID,
           availableDisplays.contains(where: { $0.displayID == selectedDisplayID }) {
            return
        }

        if let savedDisplayID = savedSelectedDisplayID(),
           availableDisplays.contains(where: { $0.displayID == savedDisplayID }) {
            applySelection(savedDisplayID)
            return
        }

        if availableDisplays.count == 1 {
            applySelection(availableDisplays[0].displayID)
            return
        }

        applySelection(nil)
    }

    private func savedSelectedDisplayID() -> CGDirectDisplayID? {
        guard userDefaults.object(forKey: selectedDisplayIDKey) != nil else {
            return nil
        }
        return CGDirectDisplayID(userDefaults.integer(forKey: selectedDisplayIDKey))
    }

    private func applySelection(_ displayID: CGDirectDisplayID?) {
        isApplyingSelection = true
        selectedDisplayID = displayID
        isApplyingSelection = false
    }

    private static func defaultDisplayProvider() async throws -> [CaptureDisplay] {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        return shareableContent.displays.enumerated().map { index, display in
            CaptureDisplay(
                displayID: display.displayID,
                name: "Display \(index + 1)",
                width: display.width,
                height: display.height
            )
        }
    }
}
