import Foundation
import SwiftData

actor SpeakerEmbeddingStore {
    private let modelContainer: ModelContainer
    private let context: ModelContext

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.context = ModelContext(modelContainer)
    }

    func fetchAll() throws -> [SpeakerProfile] {
        let descriptor = FetchDescriptor<SpeakerProfile>(sortBy: [SortDescriptor(\.lastSeen, order: .reverse)])
        return try context.fetch(descriptor)
    }

    func save(_ profile: SpeakerProfile) throws {
        context.insert(profile)
        try context.save()
    }

    func updateProfile(id: UUID) throws {
        let descriptor = FetchDescriptor<SpeakerProfile>(predicate: #Predicate<SpeakerProfile> { $0.id == id })
        if let profile = try context.fetch(descriptor).first {
            profile.lastSeen = .now
            try context.save()
        }
    }

    func delete(_ profile: SpeakerProfile) throws {
        let id = profile.persistentModelID
        if let toDelete = context.model(for: id) as? SpeakerProfile {
            context.delete(toDelete)
            try context.save()
        }
    }

    func findProfile(byID id: UUID) throws -> SpeakerProfile? {
        let descriptor = FetchDescriptor<SpeakerProfile>(predicate: #Predicate<SpeakerProfile> { $0.id == id })
        return try context.fetch(descriptor).first
    }

    func enrollSpeaker(name: String, embedding: [Float]) throws {
        let descriptor = FetchDescriptor<SpeakerProfile>()
        let allProfiles = try context.fetch(descriptor)
        
        if let existing = allProfiles.first(where: { $0.name.lowercased() == name.lowercased() }) {
            existing.embedding = embedding
            existing.lastSeen = .now
        } else {
            let newProfile = SpeakerProfile(name: name, embedding: embedding)
            context.insert(newProfile)
        }
        
        try context.save()
    }
}
