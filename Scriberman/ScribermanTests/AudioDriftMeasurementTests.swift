import Foundation
import Testing
@testable import Scriberman

struct AudioDriftMeasurementTests {
    /// A short burst embedded in silence, so cross-correlation has a clear peak.
    private func burst(at offset: Int, length: Int, burstLength: Int = 32) -> [Float] {
        var signal = [Float](repeating: 0, count: length)
        for index in 0..<burstLength where offset + index < length {
            // Simple deterministic waveform.
            signal[offset + index] = Float((index % 8) - 4)
        }
        return signal
    }

    @Test("Zero lag is detected for identical signals")
    func detectsZeroLag() {
        let a = burst(at: 100, length: 400)
        let lag = AudioDriftMeasurement.bestLagFrames(signalA: a, signalB: a, maxLagFrames: 50)
        #expect(lag == 0)
    }

    @Test("A positive lag is detected when B is delayed relative to A")
    func detectsPositiveLag() {
        let a = burst(at: 100, length: 400)
        let b = burst(at: 120, length: 400) // same content, 20 frames later
        let lag = AudioDriftMeasurement.bestLagFrames(signalA: a, signalB: b, maxLagFrames: 50)
        #expect(lag == 20)
    }

    @Test("A negative lag is detected when B is earlier than A")
    func detectsNegativeLag() {
        let a = burst(at: 120, length: 400)
        let b = burst(at: 100, length: 400)
        let lag = AudioDriftMeasurement.bestLagFrames(signalA: a, signalB: b, maxLagFrames: 50)
        #expect(lag == -20)
    }

    @Test("Silent or empty signals return nil")
    func silentSignalsReturnNil() {
        let silent = [Float](repeating: 0, count: 200)
        let burst = burst(at: 10, length: 200)
        #expect(AudioDriftMeasurement.bestLagFrames(signalA: silent, signalB: burst, maxLagFrames: 20) == nil)
        #expect(AudioDriftMeasurement.bestLagFrames(signalA: burst, signalB: [], maxLagFrames: 20) == nil)
    }
}
