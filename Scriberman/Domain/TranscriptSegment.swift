import Foundation

struct TranscriptSegment: Codable, Equatable {
    let speakerId: String
    let text: String
    let startTime: Float
    let endTime: Float
}
