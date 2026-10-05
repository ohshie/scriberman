import Foundation

/// Pipeline settings read by live transcription (`LiveTranscriptionService`)
/// and by offline passes (`TranscriptionPassRunner`). Each field says which.
struct LiveTranscriptionPipelineSettings: Sendable {
    /// Both: `VadConfig.defaultThreshold` for the live VAD and the offline
    /// speech segmentation.
    var vadThreshold: Double
    /// Both: `VadSegmentationConfig.minSpeechDuration` live and offline.
    var vadMinSpeechDuration: Double
    /// Both: ASR results below this confidence are dropped (0 disables).
    var asrConfidenceGate: Double
    /// Live only: speech buffers whose peak is below this are not transcribed
    /// (0 disables).
    var asrAmplitudeGate: Double
    /// Both: user cleanup rules applied to each segment's text.
    var cleanupRules: [TranscriptCleanupRule] = []

    static let defaults = LiveTranscriptionPipelineSettings(
        vadThreshold: 0.85,
        vadMinSpeechDuration: 0.30,
        asrConfidenceGate: 0.0,
        asrAmplitudeGate: 0.0
    )

    mutating func resetToDefaults() {
        self = Self.defaults
    }
}
