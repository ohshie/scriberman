import AppKit
import Foundation
import UniformTypeIdentifiers

enum TranscriptExportError: LocalizedError {
    case transcriptUnavailable
    case exportCancelled

    var errorDescription: String? {
        switch self {
        case .transcriptUnavailable:
            return "Transcript is not available for export."
        case .exportCancelled:
            return "Export was cancelled."
        }
    }
}

final class TranscriptExportService {
    private let markdownRenderer = MarkdownRenderer()

    @MainActor
    func export(session: RecordingSession) async throws {
        guard let transcript = session.transcript else {
            throw TranscriptExportError.transcriptUnavailable
        }

        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = markdownRenderer.defaultFileName(for: session.title)

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            throw TranscriptExportError.exportCancelled
        }

        let markdown = markdownRenderer.renderMarkdown(session: session, transcript: transcript)
        try markdown.write(to: destinationURL, atomically: true, encoding: .utf8)
    }
}
