import Foundation

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

    var status: RecordingStatus { get set }
    var transcript: Transcript? { get set }
    var retranscript: Transcript? { get set }
}
