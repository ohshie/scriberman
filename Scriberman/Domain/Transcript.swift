import Foundation

struct Transcript: Codable, Equatable {
    let fullText: String
    let segments: [TranscriptSegment]
    let speakers: [TranscriptSpeaker]
}
