import Testing
@testable import Scriberman

struct TranscriptSegmentCodableTests {
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
