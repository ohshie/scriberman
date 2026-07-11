import SwiftUI

struct FlowingWaveView: View {
    let level: Float
    var appLevel: Float = 0
    let showAppWave: Bool
    let isRecording: Bool

    // Ballistics state lives in a reference box mutated inside the Canvas
    // draw closure: TimelineView(.animation) drives redraws every frame, so
    // no SwiftUI invalidation is needed or wanted (design D2).
    @State private var smoothing = WaveSmoothingBox()

    private let idleAmplitude: CGFloat = 6
    private let maxAmplitude: CGFloat = 40
    private let waveSpeed: Double = 1.45
    private let appWavePhaseOffset: Double = 2.1

    private struct WaveLayer {
        let amplitudeMultiplier: CGFloat
        let phaseOffset: Double
        let strokeOpacity: Double
        let fillOpacity: Double
    }

    // Back-to-front echoes (design D3).
    private static let micLayers: [WaveLayer] = [
        WaveLayer(amplitudeMultiplier: 0.5, phaseOffset: 1.0, strokeOpacity: 0.35, fillOpacity: 0.08),
        WaveLayer(amplitudeMultiplier: 0.72, phaseOffset: 0.45, strokeOpacity: 0.55, fillOpacity: 0.12),
        WaveLayer(amplitudeMultiplier: 1.0, phaseOffset: 0, strokeOpacity: 0.95, fillOpacity: 0.20),
    ]

    private static let micGradient = Gradient(colors: [
        Color(red: 0.22, green: 0.54, blue: 0.87),
        Color(red: 0.33, green: 0.29, blue: 0.72),
        Color(red: 0.50, green: 0.47, blue: 0.87),
    ])
    private static let appWaveColor = Color(red: 0.85, green: 0.35, blue: 0.19)

    var body: some View {
        TimelineView(.animation) { timelineContext in
            Canvas { graphicsContext, size in
                guard size.width > 0, size.height > 0 else {
                    return
                }

                let now = timelineContext.date.timeIntervalSinceReferenceDate
                let deltaTime = smoothing.consumeDelta(now: now)

                let micTarget = isRecording ? WaveBallistics.perceptualLevel(fromRMS: level) : 0
                let appTarget = isRecording ? WaveBallistics.perceptualLevel(fromRMS: appLevel) : 0
                let mic = CGFloat(smoothing.mic.step(target: micTarget, deltaTime: deltaTime))
                let app = CGFloat(smoothing.app.step(target: appTarget, deltaTime: deltaTime))

                let phase = now * waveSpeed
                // Never dead-flat while recording: a slow breathing floor
                // signals the session is alive (design D3).
                let breathing = 3 + 1.2 * CGFloat(sin(now * 1.1))
                let micAmplitude = isRecording ? max(mic * maxAmplitude, breathing) : idleAmplitude
                let vivid = isRecording ? 0.35 + 0.65 * Double(mic) : 0.55

                let micShading = GraphicsContext.Shading.linearGradient(
                    Self.micGradient,
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                )

                if showAppWave {
                    let appIntensity = 0.3 + 0.7 * Double(app)
                    let appAmplitude = max(app * maxAmplitude * 0.9, breathing * 0.6)
                    drawLayer(
                        into: graphicsContext,
                        size: size,
                        amplitude: appAmplitude,
                        phase: phase + appWavePhaseOffset,
                        shading: .color(Self.appWaveColor),
                        strokeOpacity: 0.4 * appIntensity,
                        fillOpacity: 0.1 * appIntensity
                    )
                }

                for layer in Self.micLayers {
                    drawLayer(
                        into: graphicsContext,
                        size: size,
                        amplitude: micAmplitude * layer.amplitudeMultiplier,
                        phase: phase + layer.phaseOffset,
                        shading: micShading,
                        strokeOpacity: layer.strokeOpacity * vivid,
                        fillOpacity: layer.fillOpacity * vivid
                    )
                }
            }
        }
    }

    private func drawLayer(
        into graphicsContext: GraphicsContext,
        size: CGSize,
        amplitude: CGFloat,
        phase: Double,
        shading: GraphicsContext.Shading,
        strokeOpacity: Double,
        fillOpacity: Double
    ) {
        let path = layerPath(in: size, amplitude: amplitude, phase: phase)

        var fillContext = graphicsContext
        fillContext.opacity = fillOpacity
        fillContext.fill(path, with: shading)

        var strokeContext = graphicsContext
        strokeContext.opacity = strokeOpacity
        strokeContext.stroke(
            path,
            with: shading,
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
    }

    // Closed path from midline through the windowed wave back to the midline,
    // so it both fills cleanly and pins to the center at the edges (design D3).
    private func layerPath(in size: CGSize, amplitude: CGFloat, phase: Double) -> Path {
        var path = Path()
        let width = max(size.width, 1)
        let midY = size.height / 2
        let step: CGFloat = 2

        path.move(to: CGPoint(x: 0, y: midY))

        var x: CGFloat = 0
        while x <= width {
            let ratio = Double(x / width)
            let window = pow(sin(.pi * ratio), 0.8)
            let y = midY + amplitude * CGFloat(window * organicWave(ratio: ratio, phase: phase))
            path.addLine(to: CGPoint(x: x, y: y))
            x += step
        }

        path.addLine(to: CGPoint(x: width, y: midY))
        path.closeSubpath()
        return path
    }

    private func organicWave(ratio: Double, phase: Double) -> Double {
        let component1 = sin((4 * Double.pi * ratio) + phase)
        let component2 = 0.4 * sin((7 * Double.pi * ratio) + (1.3 * phase))
        let component3 = 0.3 * sin((2.5 * Double.pi * ratio) + (0.7 * phase))
        return (component1 + component2 + component3) / 1.7
    }
}

// Reference type so the Canvas draw closure can advance smoothing state
// without triggering SwiftUI invalidation (TimelineView owns the redraw).
private final class WaveSmoothingBox {
    var mic = WaveBallistics()
    var app = WaveBallistics()
    private var lastTime: TimeInterval?

    func consumeDelta(now: TimeInterval) -> TimeInterval {
        defer { lastTime = now }
        guard let lastTime else { return 1.0 / 60.0 }
        return min(max(now - lastTime, 0), 0.1)
    }
}
