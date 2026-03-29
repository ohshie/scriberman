import Foundation

struct Transcript: Codable, Equatable {
    let fullText: String
    let segments: [TranscriptSegment]
    let speakers: [TranscriptSpeaker]
    var speakerEmbeddings: [String: [Float]]?

    init(fullText: String, segments: [TranscriptSegment], speakers: [TranscriptSpeaker], speakerEmbeddings: [String: [Float]]? = nil) {
        self.fullText = fullText
        self.segments = segments
        self.speakers = speakers
        self.speakerEmbeddings = speakerEmbeddings
    }
}
