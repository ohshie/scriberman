import XCTest
import SwiftData
import FluidAudio
@testable import Scriberman

final class SpeakerEmbeddingStoreTests: XCTestCase {
    var container: ModelContainer!
    var store: SpeakerEmbeddingStore!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: SpeakerProfile.self, configurations: config)
        store = SpeakerEmbeddingStore(modelContainer: container)
    }

    func testEnrollNewSpeaker() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.enrollSpeaker(name: "Alice", embedding: embedding)
        
        let all = try await store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Alice")
        XCTAssertEqual(all.first?.embedding, embedding)
    }

    func testUpdateExistingSpeaker() async throws {
        let embedding1: [Float] = Array(repeating: 0.1, count: 256)
        try await store.enrollSpeaker(name: "Alice", embedding: embedding1)
        
        let embedding2: [Float] = Array(repeating: 0.2, count: 256)
        try await store.enrollSpeaker(name: "Alice", embedding: embedding2)
        
        let all = try await store.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Alice")
        XCTAssertEqual(all.first?.embedding, embedding2)
    }

    func testDeleteSpeaker() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.enrollSpeaker(name: "Alice", embedding: embedding)
        
        let all = try await store.fetchAll()
        try await store.delete(all.first!)
        
        let allAfter = try await store.fetchAll()
        XCTAssertTrue(allAfter.isEmpty)
    }

    func testFindProfileByID() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.enrollSpeaker(name: "Alice", embedding: embedding)
        
        let all = try await store.fetchAll()
        let id = all.first!.id
        
        let found = try await store.findProfile(byID: id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Alice")
    }
}
