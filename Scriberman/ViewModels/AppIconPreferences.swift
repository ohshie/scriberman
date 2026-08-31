import AppKit
import Observation

/// The app icons the user can choose between.
///
/// macOS has no alternate-icon API (`setAlternateIconName` is UIKit-only), so switching is a
/// runtime swap of `NSApplication.applicationIconImage`. That affects the Dock and app-menu
/// icon of the running app; the icon Finder shows for the bundle is unchanged. The choice is
/// persisted and re-applied on every launch, because macOS does not remember it.
enum AppIconOption: String, CaseIterable, Identifiable, Sendable {
    case classic
    case purple

    var id: String { rawValue }

    /// Asset name of the image used both for the Dock icon and the settings thumbnail.
    /// These are `imageset`s rather than `appiconset`s: SwiftUI cannot render an appiconset,
    /// and a runtime icon swap only needs a single 1024pt image.
    var assetName: String {
        switch self {
        case .classic: return "AppIconClassic"
        case .purple: return "AppIconPurple"
        }
    }

    var image: NSImage? {
        NSImage(named: assetName)
    }
}

/// Persists the selected app icon and applies it to the running app.
@MainActor
@Observable
final class AppIconPreferences {
    private enum Key {
        static let selectedIcon = "appIcon.selected"
    }

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let application: NSApplication?

    var selectedIcon: AppIconOption {
        didSet {
            userDefaults.set(selectedIcon.rawValue, forKey: Key.selectedIcon)
            apply()
        }
    }

    init(userDefaults: UserDefaults = .standard, application: NSApplication? = .shared) {
        self.userDefaults = userDefaults
        self.application = application
        let stored = userDefaults.string(forKey: Key.selectedIcon)
        selectedIcon = stored.flatMap(AppIconOption.init(rawValue:)) ?? .classic
    }

    /// Applies the stored choice. Called at launch and whenever the selection changes, since
    /// macOS resets to the bundle icon on every launch.
    func apply() {
        guard let application else { return }
        switch selectedIcon {
        case .classic:
            // nil restores the icon baked into the bundle.
            application.applicationIconImage = nil
        case .purple:
            if let image = selectedIcon.image {
                application.applicationIconImage = image
            }
        }
    }
}
