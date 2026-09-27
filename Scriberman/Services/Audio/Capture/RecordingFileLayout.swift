import Foundation

/// Names and creates recording folders, and locates the files inside one.
///
/// A folder is named once, when the recording starts, and its URL is then held for the whole
/// recording. Nothing rebuilds it from the start date later, so a time-zone change mid-recording
/// cannot point finalization at a different folder. Folders created under the earlier
/// `Recording MMM dd at HH-mm xx` pattern keep their names; everything after start reaches them
/// through the stored file URLs.
enum RecordingFileLayout {
    /// Highest collision suffix tried before a start fails.
    static let maximumFolderSuffix = 99

    static func folderName(createdAt: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        // Hyphens stand in for colons, which Finder shows as slashes.
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter.string(from: createdAt)
    }

    /// Creates a new folder for a recording and returns its URL.
    ///
    /// The session folder is created without accepting an existing directory, so the create call
    /// itself is the uniqueness check and two recordings can never share a folder. A taken name
    /// gets ` 2`, then ` 3`, up to ``maximumFolderSuffix``; past that the last error is thrown.
    static func createRecordingFolder(
        in workspace: Workspace,
        createdAt: Date,
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: workspace.recordingsURL, withIntermediateDirectories: true)
        let baseName = folderName(createdAt: createdAt, timeZone: timeZone)
        var lastError: Error?
        for suffix in 1...maximumFolderSuffix {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let folderURL = workspace.recordingsURL.appendingPathComponent(name, isDirectory: true)
            do {
                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
                return folderURL
            } catch CocoaError.fileWriteFileExists {
                lastError = CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: folderURL.path])
            }
        }
        throw lastError ?? CocoaError(.fileWriteFileExists)
    }

    static func recordingFileURLs(in folderURL: URL) -> (mic: URL, app: URL) {
        (
            folderURL.appendingPathComponent("mic.wav"),
            folderURL.appendingPathComponent("app.wav")
        )
    }

    static func screenTmpVideoURL(in folderURL: URL) -> URL {
        folderURL.appendingPathComponent("screen-tmp.mov")
    }

    static func screenVideoURL(in folderURL: URL) -> URL {
        folderURL.appendingPathComponent("screen.mov")
    }
}
