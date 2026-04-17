import Foundation

enum RecordingFileLayout {
    static func folderName(createdAt: Date, recordingIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd 'at' HH-mm"
        let suffix = String(recordingIdentifier.suffix(2))
        return "Recording \(formatter.string(from: createdAt)) \(suffix)"
    }

    static func recordingFolderURL(
        in workspace: Workspace,
        createdAt: Date,
        recordingIdentifier: String
    ) -> URL {
        let folderName = folderName(createdAt: createdAt, recordingIdentifier: recordingIdentifier)
        return workspace.recordingsURL.appendingPathComponent(folderName, isDirectory: true)
    }

    static func recordingFileURLs(
        in workspace: Workspace,
        createdAt: Date,
        recordingIdentifier: String
    ) -> (mic: URL, app: URL) {
        let folderURL = recordingFolderURL(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: recordingIdentifier
        )

        return (
            folderURL.appendingPathComponent("mic.wav"),
            folderURL.appendingPathComponent("app.wav")
        )
    }
}
