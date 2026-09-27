import Foundation
import SwiftData

@Model
final class SpeakerProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var embedding: [Float]
    var lastSeen: Date

    init(id: UUID = UUID(), name: String, embedding: [Float], lastSeen: Date = .now) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.lastSeen = lastSeen
    }
}

extension SpeakerProfile {
    static func fetch(id: UUID, in context: ModelContext) throws -> SpeakerProfile? {
        let targetID = id
        var descriptor = FetchDescriptor<SpeakerProfile>(predicate: #Predicate { $0.id == targetID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

struct SpeakerProfileSnapshot: Sendable, Identifiable {
    let id: UUID
    let name: String
    let embedding: [Float]
    let lastSeen: Date

    init(profile: SpeakerProfile) {
        self.id = profile.id
        self.name = profile.name
        self.embedding = profile.embedding
        self.lastSeen = profile.lastSeen
    }
}
