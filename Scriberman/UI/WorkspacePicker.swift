import AppKit
import Foundation

enum WorkspacePicker {
    @MainActor
    static func chooseWorkspaceFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select Scriberman Workspace"
        panel.message = "Recommended: ~/Documents/Scriberman"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        let defaultURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Scriberman", isDirectory: true)
        panel.directoryURL = defaultURL

        return await runAttachedToWindow(panel) == .OK ? panel.url : nil
    }
}
