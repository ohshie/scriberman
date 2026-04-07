import Foundation

enum RecordingFileLayout {
    static func recordingFileURLs(in workspace: Workspace) -> (mic: URL, app: URL) {
        (
            workspace.tmpRecordingURL.appendingPathComponent("mic.wav"),
            workspace.tmpRecordingURL.appendingPathComponent("app.wav")
        )
    }

    static func folderName(createdAt: Date, recordingIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd 'at' HH-mm"
        let suffix = String(recordingIdentifier.suffix(2))
        return "Recording \(formatter.string(from: createdAt)) \(suffix)"
    }

    static func promoteTmpRecordingFolder(
        in workspace: Workspace,
        createdAt: Date,
        recordingIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> (mic: URL, app: URL?) {
        let folderName = folderName(createdAt: createdAt, recordingIdentifier: recordingIdentifier)
        let namedFolderURL = workspace.recordingsURL.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.moveItem(at: workspace.tmpRecordingURL, to: namedFolderURL)

        let micURL = namedFolderURL.appendingPathComponent("mic.wav")
        let appURL = namedFolderURL.appendingPathComponent("app.wav")
        let finalAppURL = fileManager.fileExists(atPath: appURL.path) ? appURL : nil
        return (micURL, finalAppURL)
    }
}
