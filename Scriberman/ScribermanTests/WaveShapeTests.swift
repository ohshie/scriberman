import CoreGraphics
import Testing
@testable import Scriberman

/// Expected values were computed from the SwiftUI wave's formula before the native view replaced it.
@Suite
struct WaveShapeTests {
    @Test
    func outlineStartsAndEndsOnTheMidline() {
        let points = WaveShape.outline(in: CGSize(width: 100, height: 80), amplitude: 40, phase: 0.5)

        #expect(points.first == CGPoint(x: 0, y: 40))
        #expect(points.last == CGPoint(x: 100, y: 40))
    }

    @Test
    func outlineSamplesEveryTwoPoints() {
        let points = WaveShape.outline(in: CGSize(width: 100, height: 80), amplitude: 40, phase: 0.5)

        // Midline start, samples at x = 0, 2, ... 100, midline end.
        #expect(points.count == 53)
        #expect(points[1].x == 0)
        #expect(points[2].x == 2)
        #expect(points[51].x == 100)
    }

    @Test
    func outlineMatchesTheWaveFormula() {
        let points = WaveShape.outline(in: CGSize(width: 100, height: 80), amplitude: 40, phase: 0.5)
        let samples = Dictionary(points.dropFirst().dropLast().map { ($0.x, $0.y) }, uniquingKeysWith: { first, _ in first })

        expectClose(samples[0], 40.0)
        expectClose(samples[26], 33.651037915916156)
        expectClose(samples[50], 37.3877968263073)
        expectClose(samples[74], 25.803774146698984)
        expectClose(samples[100], 40.0)
    }

    @Test
    func outlineScalesWithSizeAndPhase() {
        let points = WaveShape.outline(in: CGSize(width: 30, height: 20), amplitude: 10, phase: 2.0)
        let samples = Dictionary(points.dropFirst().dropLast().map { ($0.x, $0.y) }, uniquingKeysWith: { first, _ in first })

        #expect(points.count == 18)
        expectClose(samples[0], 10.0)
        expectClose(samples[10], 7.2814161321323825)
        expectClose(samples[30], 10.0)
    }

    private func expectClose(_ actual: CGFloat?, _ expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let actual else {
            Issue.record("No sample at this x", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(Double(actual) - expected) < 1e-9, sourceLocation: sourceLocation)
    }
}
