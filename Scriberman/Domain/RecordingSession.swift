import Foundation
import SwiftData

@Model
final class RecordingSession {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    var audioURL: String
    var title: String
    var statusRawValue: String
    var errorMessage: String?
    var transcriptData: Data?

    var status: RecordingStatus {
        get { RecordingStatus(persistedValue: statusRawValue, errorMessage: errorMessage) }
        set {
            statusRawValue = newValue.persistedValue
            switch newValue {
            case .error(let message):
                errorMessage = message
            default:
                errorMessage = nil
            }
        }
    }

    var transcript: Transcript? {
        get {
            guard let transcriptData else { return nil }
            return try? JSONDecoder().decode(Transcript.self, from: transcriptData)
        }
        set {
            if let newValue {
                transcriptData = try? JSONEncoder().encode(newValue)
            } else {
                transcriptData = nil
            }
        }
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        duration: TimeInterval,
        audioURL: String,
        title: String,
        status: RecordingStatus = .recorded,
        errorMessage: String? = nil,
        transcriptData: Data? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.audioURL = audioURL
        self.title = title
        self.statusRawValue = status.persistedValue
        self.errorMessage = errorMessage
        self.transcriptData = transcriptData
        if case .error = status {
            self.status = status
        }
    }
}
