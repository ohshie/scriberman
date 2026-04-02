import SwiftUI

struct FlowingWaveView: View {
    let level: Float
    let showAppWave: Bool
    let isRecording: Bool

    private let idleAmplitude: CGFloat = 6
    private let maxAmplitude: CGFloat = 44
    private let appAmbientAmplitude: CGFloat = 9
    private let waveSpeed: Double = 2.25
    private let appWavePhaseOffset: Double = .pi / 3

    var body: some View {
        TimelineView(.animation) { timelineContext in
            Canvas { graphicsContext, size in
                guard size.width > 0, size.height > 0 else {
                    return
                }

                let elapsed = timelineContext.date.timeIntervalSinceReferenceDate
                let phase = elapsed * waveSpeed
                let primaryAmplitude = isRecording
                    ? CGFloat(max(0, min(level, 1))) * maxAmplitude
                    : idleAmplitude

                let primaryPath = wavePath(
                    in: size,
                    amplitude: primaryAmplitude,
                    phase: phase
                )
                graphicsContext.stroke(
                    primaryPath,
                    with: .color(.blue.opacity(0.8)),
                    lineWidth: 2
                )

                if showAppWave {
                    let appPath = wavePath(
                        in: size,
                        amplitude: appAmbientAmplitude,
                        phase: phase + appWavePhaseOffset
                    )
                    graphicsContext.stroke(
                        appPath,
                        with: .color(.red.opacity(0.8)),
                        lineWidth: 2
                    )
                }
            }
        }
    }

    private func wavePath(in size: CGSize, amplitude: CGFloat, phase: Double) -> Path {
        var path = Path()
        let width = max(size.width, 1)
        let midY = size.height / 2
        let step: CGFloat = 1

        path.move(to: CGPoint(x: 0, y: yPosition(x: 0, width: width, midY: midY, amplitude: amplitude, phase: phase)))

        var x: CGFloat = step
        while x <= width {
            path.addLine(
                to: CGPoint(
                    x: x,
                    y: yPosition(x: x, width: width, midY: midY, amplitude: amplitude, phase: phase)
                )
            )
            x += step
        }

        return path
    }

    private func yPosition(
        x: CGFloat,
        width: CGFloat,
        midY: CGFloat,
        amplitude: CGFloat,
        phase: Double
    ) -> CGFloat {
        let ratio = Double(x / width)
        let component1 = sin((4 * Double.pi * ratio) + phase)
        let component2 = 0.4 * sin((7 * Double.pi * ratio) + (1.3 * phase))
        let component3 = 0.3 * sin((2.5 * Double.pi * ratio) + (0.7 * phase))
        let organicWave = (component1 + component2 + component3) / 1.7
        return midY + (amplitude * CGFloat(organicWave))
    }
}
