import Foundation

/// Meter ballistics for audio level displays (design D1): exponential
/// attack/release smoothing stepped once per rendered frame, plus the
/// perceptual dB mapping that lets normal speech fill the visual range.
/// Fast attack keeps onsets responsive; slow release keeps decay calm —
/// the same envelope behavior as a hardware VU meter.
struct WaveBallistics {
    var attackTimeConstant: TimeInterval = 0.05
    var releaseTimeConstant: TimeInterval = 0.3

    private(set) var smoothedLevel: Float = 0

    @discardableResult
    mutating func step(target: Float, deltaTime: TimeInterval) -> Float {
        let clampedTarget = min(max(target, 0), 1)
        guard deltaTime > 0 else { return smoothedLevel }

        let timeConstant = clampedTarget >= smoothedLevel ? attackTimeConstant : releaseTimeConstant
        let alpha = Float(1 - exp(-deltaTime / timeConstant))
        smoothedLevel += (clampedTarget - smoothedLevel) * alpha
        return smoothedLevel
    }

    /// Maps raw linear RMS to a perceptual 0–1 level: −50dB → 0, 0dB → 1.
    /// Speech RMS (~0.01–0.2) lands mid-range instead of hugging the floor.
    static func perceptualLevel(fromRMS rms: Float) -> Float {
        let floored = max(rms, 1e-5)
        let decibels = 20 * log10(floored)
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
