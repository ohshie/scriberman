import Foundation
import SwiftData

actor SpeakerEmbeddingStore {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func fetchAll() throws -> [SpeakerProfile] {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<SpeakerProfile>(sortBy: [SortDescriptor(\.lastSeen, order: .reverse)])
        return try context.fetch(descriptor)
    }

    func save(_ profile: SpeakerProfile) throws {
        let context = ModelContext(modelContainer)
        context.insert(profile)
        try context.save()
    }

    func updateProfile(id: UUID) throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<SpeakerProfile>(predicate: #Predicate { $0.id == id })
        if let profile = try context.fetch(descriptor).first {
            profile.lastSeen = .now
            try context.save()
        }
    }

    func delete(_ profile: SpeakerProfile) throws {
        let context = ModelContext(modelContainer)
        context.delete(profile)
        try context.save()
    }

    func findProfile(byID id: UUID) throws -> SpeakerProfile? {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<SpeakerProfile>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    func enrollSpeaker(name: String, embedding: [Float]) throws {
        let context = ModelContext(modelContainer)
        
        // Try to find existing profile by name (case-insensitive)
        let nameLower = name.lowercased()
        let descriptor = FetchDescriptor<SpeakerProfile>()
        let allProfiles = try context.fetch(descriptor)
        
        if let existing = allProfiles.first(where: { $0.name.lowercased() == nameLower }) {
            // Update embedding (average) and lastSeen
            // For simplicity, we can just replace or use EMA
            existing.embedding = embedding // Or average it
            existing.lastSeen = .now
        } else {
            // Create new profile
            let newProfile = SpeakerProfile(name: name, embedding: embedding)
            context.insert(newProfile)
        }
        
        try context.save()
    }
}
