import Foundation

struct AIPrompt: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var content: String

    init(id: UUID = UUID(), name: String, content: String) {
        self.id = id
        self.name = name
        self.content = content
    }
}

struct AITransformation: Codable, Equatable, Identifiable {
    let id: UUID
    var promptName: String
    var modelID: String
    var resultText: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        promptName: String,
        modelID: String,
        resultText: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.promptName = promptName
        self.modelID = modelID
        self.resultText = resultText
        self.createdAt = createdAt
    }
}

protocol TranscribableSession: AnyObject {
    var id: UUID { get set }
    var createdAt: Date { get set }
    var duration: TimeInterval { get set }
    var title: String { get set }
    var mixdownURL: String? { get set }
    var statusRawValue: String { get set }
    var errorMessage: String? { get set }
    var transcriptData: Data? { get set }
    var retranscriptData: Data? { get set }
    var aiTransformationsData: Data? { get set }

    var status: RecordingStatus { get set }
    var transcript: Transcript? { get set }
    var retranscript: Transcript? { get set }
}
