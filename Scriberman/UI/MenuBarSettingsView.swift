import SwiftUI

struct MenuBarSettingsView: View {
    var menuBarSettings: MenuBarSettings
    var availableDevices: [AudioInputDevice]
    var runningApps: [CapturedApp]

    var body: some View {
        @Bindable var bindableSettings = menuBarSettings

        Picker("When closing main window", selection: $bindableSettings.closeAction) {
            Text("Ask every time").tag(MenuBarSettings.CloseAction.ask)
            Text("Keep in menu bar").tag(MenuBarSettings.CloseAction.tray)
            Text("Quit Scriberman").tag(MenuBarSettings.CloseAction.quit)
        }

        LabeledContent("Last used microphone") {
            Text(lastUsedMicrophoneName)
        }

        LabeledContent("Last used app audio") {
            Text(lastUsedAppName)
        }

        Button("Reset to Defaults") {
            menuBarSettings.lastUsedMicUID = nil
            menuBarSettings.lastUsedAppBundleID = nil
        }
    }

    private var lastUsedMicrophoneName: String {
        guard let uid = menuBarSettings.lastUsedMicUID else {
            return "System Default"
        }

        return availableDevices.first(where: { $0.uid == uid })?.name ?? "System Default"
    }

    private var lastUsedAppName: String {
        guard let bundleID = menuBarSettings.lastUsedAppBundleID else {
            return "None"
        }

        return runningApps.first(where: { $0.bundleID == bundleID })?.name ?? "None"
    }
}
