import Foundation
import Testing
@testable import Scriberman

struct TranscriptExportServiceTests {
    private let service = TranscriptExportService()

    @Test
    func writePersistsMarkdownToProvidedURL() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try service.write("# Exported Transcript", to: outputURL)

        let written = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(written == "# Exported Transcript")
    }
}
