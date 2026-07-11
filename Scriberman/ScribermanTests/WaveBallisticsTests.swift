import Foundation
import Testing
@testable import Scriberman

@Suite
struct WaveBallisticsTests {
    @Test
    func attackIsFasterThanRelease() {
        var rising = WaveBallistics()
        rising.step(target: 1, deltaTime: 0.05)
        let riseAmount = rising.smoothedLevel

        var falling = WaveBallistics()
        for _ in 0..<200 {
            falling.step(target: 1, deltaTime: 0.05)
        }
        let peak = falling.smoothedLevel
        falling.step(target: 0, deltaTime: 0.05)
        let fallAmount = peak - falling.smoothedLevel

        #expect(riseAmount > fallAmount * 2)
    }

    @Test
    func outputStaysBoundedForOutOfRangeTargets() {
        var ballistics = WaveBallistics()
        for _ in 0..<100 {
            ballistics.step(target: 5, deltaTime: 0.1)
        }
        #expect(ballistics.smoothedLevel <= 1)

        for _ in 0..<100 {
            ballistics.step(target: -3, deltaTime: 0.1)
        }
        #expect(ballistics.smoothedLevel >= 0)
    }

    @Test
    func convergesToHeldTarget() {
        var ballistics = WaveBallistics()
        for _ in 0..<300 {
            ballistics.step(target: 0.8, deltaTime: 1.0 / 60.0)
        }
        #expect(abs(ballistics.smoothedLevel - 0.8) < 0.01)
    }

    @Test
    func deltaTimeRobustness() {
        var manySmall = WaveBallistics()
        for _ in 0..<10 {
            manySmall.step(target: 1, deltaTime: 0.03)
        }

        var oneLarge = WaveBallistics()
        oneLarge.step(target: 1, deltaTime: 0.3)

        #expect(abs(manySmall.smoothedLevel - oneLarge.smoothedLevel) < 0.02)
    }

    @Test
    func zeroDeltaTimeLeavesLevelUnchanged() {
        var ballistics = WaveBallistics()
        ballistics.step(target: 1, deltaTime: 0.05)
        let before = ballistics.smoothedLevel
        ballistics.step(target: 1, deltaTime: 0)
        #expect(ballistics.smoothedLevel == before)
    }

    @Test
    func perceptualMappingBounds() {
        #expect(WaveBallistics.perceptualLevel(fromRMS: 0) == 0)
        #expect(WaveBallistics.perceptualLevel(fromRMS: 1) == 1)
        #expect(WaveBallistics.perceptualLevel(fromRMS: 2) == 1)
    }

    @Test
    func perceptualMappingPutsSpeechInTheVisibleRange() {
        let quietSpeech = WaveBallistics.perceptualLevel(fromRMS: 0.05)
        let normalSpeech = WaveBallistics.perceptualLevel(fromRMS: 0.1)
        #expect(quietSpeech > 0.4)
        #expect(normalSpeech > 0.55)
        #expect(normalSpeech < 0.85)
        #expect(normalSpeech > quietSpeech)
    }
}
