import CoreGraphics
import Foundation
import ScreenCaptureKit

protocol ScreenRecordingPermissionProviding {
    func preflightAccess() -> Bool
    func requestAccess() -> Bool
}

struct CoreGraphicsScreenRecordingPermissionProvider: ScreenRecordingPermissionProviding {
    func preflightAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

struct ScreenRecordingShareableContentSnapshot {
    let windowCount: Int
    let applicationCount: Int

    var hasVisibleContent: Bool {
        windowCount > 0 || applicationCount > 0
    }
}

protocol ScreenRecordingFunctionalPermissionProviding {
    func shareableContentSnapshot() async throws -> ScreenRecordingShareableContentSnapshot
}

struct ScreenCaptureKitFunctionalPermissionProvider: ScreenRecordingFunctionalPermissionProviding {
    func shareableContentSnapshot() async throws -> ScreenRecordingShareableContentSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return ScreenRecordingShareableContentSnapshot(
            windowCount: content.windows.count,
            applicationCount: content.applications.count
        )
    }
}
