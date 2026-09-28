import Foundation
import Testing
@testable import Scriberman

struct TranscriptSegmentCodableTests {
    @Test
    func legacyIDsAreStableAcrossDecodes() throws {
        let data = Data("""
        {"speakerId":"S1","text":"migration next week","startTime":2.5,"endTime":4}
        """.utf8)
        let first = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        let second = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        #expect(first.id == second.id)
    }

    @Test
    func storedIDIsPreserved() throws {
        let data = Data("""
        {"id":"12345678-1234-4234-8234-123456789ABC","speakerId":"S1",
         "text":"hello","startTime":0,"endTime":1}
        """.utf8)
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        #expect(segment.id == UUID(uuidString: "12345678-1234-4234-8234-123456789ABC"))
    }

    @Test(arguments: ["startTime", "endTime", "speakerId", "audioSource", "text"])
    func legacyIDIncludesEachContentField(field: String) throws {
        var payload: [String: Any] = [
            "speakerId": "S1", "text": "hello", "startTime": 0, "endTime": 1, "audioSource": "mic"
        ]
        let original = try JSONDecoder().decode(
            TranscriptSegment.self, from: JSONSerialization.data(withJSONObject: payload)
        )
        switch field {
        case "startTime": payload[field] = 0.5
        case "endTime": payload[field] = 2
        case "speakerId": payload[field] = "S2"
        case "audioSource": payload[field] = "app"
        default: payload[field] = "goodbye"
        }
        let changed = try JSONDecoder().decode(
            TranscriptSegment.self, from: JSONSerialization.data(withJSONObject: payload)
        )
        #expect(original.id != changed.id)
    }

    @Test
    func decodeLegacySegmentWithoutAudioSourceDefaultsToMic() throws {
        let json = """
        {
          "speakerId": "S1",
          "text": "hello",
          "startTime": 0.0,
          "endTime": 1.0
        }
        """

        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(json.utf8))

        #expect(segment.audioSource == .mic)
    }

    @Test
    func encodeAndDecodePreservesAudioSource() throws {
        let original = TranscriptSegment(
            speakerId: "S2",
            text: "app audio",
            startTime: 2.0,
            endTime: 3.0,
            audioSource: .app
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: encoded)

        #expect(decoded == original)
        #expect(decoded.audioSource == .app)
    }
}

struct TranscriptCodableTests {
    @Test
    func transcriptWithoutProfileLinksDecodesWithNil() throws {
        let data = Data("""
        {"fullText":"hello","segments":[],"speakers":[],"speakerEmbeddings":{"S1":[0.5]}}
        """.utf8)
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(transcript.speakerProfileIDs == nil)
        #expect(transcript.speakerEmbeddings == ["S1": [0.5]])
    }

    @Test
    func profileLinksRoundTrip() throws {
        let profileID = UUID()
        let transcript = Transcript(fullText: "", segments: [], speakers: [], speakerProfileIDs: ["S1": profileID])
        let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))
        #expect(decoded.speakerProfileIDs == ["S1": profileID])
    }
}
