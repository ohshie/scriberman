import Foundation

struct LiveTranscriptionPipelineSettings: Sendable {
    var vadThreshold: Double
    var vadMinSpeechDuration: Double
    var asrConfidenceGate: Double
    var asrAmplitudeGate: Double
    var speakerSimilarityThreshold: Double
    var minSilenceGap: Double

    static let defaults = LiveTranscriptionPipelineSettings(
        vadThreshold: 0.85,
        vadMinSpeechDuration: 0.30,
        asrConfidenceGate: 0.0,
        asrAmplitudeGate: 0.0,
        speakerSimilarityThreshold: 0.65,
        minSilenceGap: 0.50
    )
}
