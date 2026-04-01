import Foundation

enum TranscriptExportError: LocalizedError, Equatable {
    case transcriptUnavailable

    var errorDescription: String? {
        switch self {
        case .transcriptUnavailable:
            return "Transcript is not available for export."
        }
    }
}

final class TranscriptExportService {
    func write(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
