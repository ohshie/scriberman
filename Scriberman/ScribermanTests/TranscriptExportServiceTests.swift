import XCTest
@testable import Scriberman

final class TranscriptExportServiceTests: XCTestCase {
    private let service = TranscriptExportService()

    func testWritePersistsMarkdownToProvidedURL() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try service.write("# Exported Transcript", to: outputURL)

        let written = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(written, "# Exported Transcript")
    }
}
