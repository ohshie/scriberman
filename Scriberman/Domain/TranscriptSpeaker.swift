import Foundation

struct TranscriptSpeaker: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let colorHex: String
}
