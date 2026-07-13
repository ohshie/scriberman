import Foundation

/// Dev/diagnostics utility: estimates the alignment offset (in frames) between two
/// mono signals via normalized cross-correlation over a bounded lag window. Used to
/// quantify mic↔app drift at the start vs. after long durations, so the sync work is
/// measurement-gated rather than judged by ear.
///
/// A positive returned lag means `signalB` is delayed relative to `signalA` (i.e.
/// B's content appears `lag` frames later than A's).
enum AudioDriftMeasurement {
    /// Best-lag estimate of `signalB` relative to `signalA`, searched over
    /// `-maxLagFrames ... +maxLagFrames`. Returns `nil` if either signal is empty or
    /// effectively silent. Intended for short analysis windows (e.g. a click), not
    /// whole recordings — slice out aligned windows near start and end and compare.
    static func bestLagFrames(
        signalA: [Float],
        signalB: [Float],
        maxLagFrames: Int
    ) -> Int? {
        guard !signalA.isEmpty, !signalB.isEmpty, maxLagFrames >= 0 else { return nil }
        guard energy(signalA) > .ulpOfOne, energy(signalB) > .ulpOfOne else { return nil }

        var bestLag = 0
        var bestScore = -Float.greatestFiniteMagnitude

        for lag in -maxLagFrames...maxLagFrames {
            let score = normalizedCorrelation(signalA, signalB, lag: lag)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        return bestLag
    }

    private static func energy(_ signal: [Float]) -> Float {
        var sum: Float = 0
        for value in signal { sum += value * value }
        return sum
    }

    /// Dot product of A and B where B is shifted by `lag`, normalized by the overlap
    /// length so different lags are comparable. Convention: `score(lag)` aligns `a[i]`
    /// with `b[i + lag]`, so the peak lag is positive when B's content is delayed
    /// relative to A (B's features appear at a later index).
    private static func normalizedCorrelation(_ a: [Float], _ b: [Float], lag: Int) -> Float {
        var dot: Float = 0
        var count = 0
        for index in 0..<a.count {
            let bIndex = index + lag
            if bIndex >= 0, bIndex < b.count {
                dot += a[index] * b[bIndex]
                count += 1
            }
        }
        guard count > 0 else { return -Float.greatestFiniteMagnitude }
        return dot / Float(count)
    }
}
