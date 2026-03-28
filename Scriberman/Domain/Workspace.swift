import Foundation

struct Workspace: Equatable {
    let rootURL: URL

    var modelsURL: URL {
        rootURL.appendingPathComponent("models", isDirectory: true)
    }

    var jobsURL: URL {
        rootURL.appendingPathComponent("jobs", isDirectory: true)
    }

    var recordingsURL: URL {
        rootURL.appendingPathComponent("recordings", isDirectory: true)
    }

    var importsURL: URL {
        rootURL.appendingPathComponent("imports", isDirectory: true)
    }

    var tmpRecordingURL: URL {
        recordingsURL.appendingPathComponent("tmp", isDirectory: true)
    }
}
