import Foundation
import SwiftData

@Model
final class RecordingSession {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    @Attribute(originalName: "audioURL") var micAudioURL: String
    var appAudioURL: String?
    @Attribute var mixdownURL: String?
    var title: String
    var capturedAppName: String?
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
        micAudioURL: String,
        appAudioURL: String? = nil,
        mixdownURL: String? = nil,
        title: String,
        capturedAppName: String? = nil,
        status: RecordingStatus = .recorded,
        errorMessage: String? = nil,
        transcriptData: Data? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.micAudioURL = micAudioURL
        self.appAudioURL = appAudioURL
        self.mixdownURL = mixdownURL
        self.title = title
        self.capturedAppName = capturedAppName
        self.statusRawValue = status.persistedValue
        self.errorMessage = errorMessage
        self.transcriptData = transcriptData
        if case .error = status {
            self.status = status
        }
    }
}
