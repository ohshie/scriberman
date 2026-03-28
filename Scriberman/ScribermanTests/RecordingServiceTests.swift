import Foundation
import XCTest
@testable import Scriberman

final class RecordingServiceTests: XCTestCase {
    func testStartRecordingUsesTmpFolderMicPath() {
        let workspace = makeWorkspace()
        let urls = RecordingService.recordingFileURLs(in: workspace)

        XCTAssertTrue(urls.mic.path.hasSuffix("/recordings/tmp/mic.wav"))
        XCTAssertTrue(urls.app.path.hasSuffix("/recordings/tmp/app.wav"))
    }

    func testStopRecordingPromotesTmpFolderToNamedFolderPattern() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        try FileManager.default.createDirectory(at: workspace.tmpRecordingURL, withIntermediateDirectories: true)
        let tmpMicURL = workspace.tmpRecordingURL.appendingPathComponent("mic.wav")
        _ = FileManager.default.createFile(atPath: tmpMicURL.path, contents: Data("mic".utf8))

        let createdAt = Date(timeIntervalSince1970: 1_743_171_000) // 2025-03-28 14:30 UTC
        let result = try RecordingService.promoteTmpRecordingFolder(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: "12345678-a3"
        )

        let folderName = result.mic.deletingLastPathComponent().lastPathComponent
        let expectedPattern = #"^Recording [A-Z][a-z]{2} \d{2} at \d{2}-\d{2} [A-Za-z0-9]{2}$"#

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.tmpRecordingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mic.path))
        XCTAssertNotNil(folderName.range(of: expectedPattern, options: .regularExpression))
    }

    func testStopRecordingMicPathUsesNamedFolderNotTmp() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        try FileManager.default.createDirectory(at: workspace.tmpRecordingURL, withIntermediateDirectories: true)
        let tmpMicURL = workspace.tmpRecordingURL.appendingPathComponent("mic.wav")
        _ = FileManager.default.createFile(atPath: tmpMicURL.path, contents: Data("mic".utf8))

        let createdAt = Date(timeIntervalSince1970: 1_743_171_000)
        let result = try RecordingService.promoteTmpRecordingFolder(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: "abcdef12"
        )
        let folderName = RecordingService.folderName(createdAt: createdAt, recordingIdentifier: "abcdef12")

        XCTAssertTrue(result.mic.path.hasSuffix("/recordings/\(folderName)/mic.wav"))
        XCTAssertFalse(result.mic.path.contains("/recordings/tmp/"))
    }

    func testFolderBasedPathExpectationUsesNamedFolderMicFile() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        try FileManager.default.createDirectory(at: workspace.tmpRecordingURL, withIntermediateDirectories: true)
        let tmpMicURL = workspace.tmpRecordingURL.appendingPathComponent("mic.wav")
        _ = FileManager.default.createFile(atPath: tmpMicURL.path, contents: Data("mic".utf8))
        let tmpAppURL = workspace.tmpRecordingURL.appendingPathComponent("app.wav")
        _ = FileManager.default.createFile(atPath: tmpAppURL.path, contents: Data("app".utf8))

        let createdAt = Date(timeIntervalSince1970: 1_743_171_000)
        let result = try RecordingService.promoteTmpRecordingFolder(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: "11111111-a3"
        )
        let folderName = RecordingService.folderName(createdAt: createdAt, recordingIdentifier: "11111111-a3")

        XCTAssertEqual(result.mic.path, workspace.recordingsURL.appendingPathComponent("\(folderName)/mic.wav").path)
        XCTAssertEqual(result.app?.path, workspace.recordingsURL.appendingPathComponent("\(folderName)/app.wav").path)
    }

    private func makeWorkspace() -> Workspace {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return Workspace(rootURL: rootURL)
    }

    private func removeWorkspace(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
