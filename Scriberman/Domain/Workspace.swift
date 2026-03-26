import Foundation

struct Workspace: Equatable {
    let rootURL: URL

    var modelsURL: URL {
        rootURL.appendingPathComponent("models", isDirectory: true)
    }

    var jobsURL: URL {
        rootURL.appendingPathComponent("jobs", isDirectory: true)
    }
}
