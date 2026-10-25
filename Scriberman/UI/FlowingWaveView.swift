import AppKit
import SwiftUI

/// The recording wave. An AppKit view draws it: a display link marks only that view for display,
/// so the animation causes no SwiftUI update and no window layout.
struct FlowingWaveView: NSViewRepresentable {
    /// Read on each drawn frame. The levels change outside observation.
    let levelBox: MeterLevelBox
    let showAppWave: Bool

    func makeNSView(context: Context) -> FlowingWaveNSView {
        FlowingWaveNSView(levelBox: levelBox)
    }

    func updateNSView(_ nsView: FlowingWaveNSView, context: Context) {
        nsView.showAppWave = showAppWave
    }
}

final class FlowingWaveNSView: NSView {
    private let levelBox: MeterLevelBox
    var showAppWave = false {
        didSet { needsDisplay = true }
    }

    private var link: CADisplayLink?
    private var linkUsesReducedRate = false
    private var mic = WaveBallistics()
    private var app = WaveBallistics()
    private var lastDrawTime: TimeInterval?

    private let maxAmplitude: CGFloat = 40
    private let waveSpeed: Double = 1.45
    private let appWavePhaseOffset: Double = 2.1
    private static let frameRate = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
    // With Reduce Motion the wave has no phase motion or breathing but still follows the levels,
    // so the link keeps running at a low rate instead of stopping.
    private static let reducedMotionFrameRate = CAFrameRateRange(minimum: 8, maximum: 10, preferred: 10)
    private static let reducedMotionInterval: TimeInterval = 0.1

    private struct WaveLayer {
        let amplitudeMultiplier: CGFloat
        let phaseOffset: Double
        let strokeOpacity: CGFloat
        let fillOpacity: CGFloat
    }

    // Back-to-front echoes (design D3).
    private static let micLayers: [WaveLayer] = [
        WaveLayer(amplitudeMultiplier: 0.5, phaseOffset: 1.0, strokeOpacity: 0.35, fillOpacity: 0.08),
        WaveLayer(amplitudeMultiplier: 0.72, phaseOffset: 0.45, strokeOpacity: 0.55, fillOpacity: 0.12),
        WaveLayer(amplitudeMultiplier: 1.0, phaseOffset: 0, strokeOpacity: 0.95, fillOpacity: 0.20),
    ]

    private static let micGradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
            CGColor(srgbRed: 0.22, green: 0.54, blue: 0.87, alpha: 1),
            CGColor(srgbRed: 0.33, green: 0.29, blue: 0.72, alpha: 1),
            CGColor(srgbRed: 0.50, green: 0.47, blue: 0.87, alpha: 1),
        ] as CFArray,
        locations: [0, 0.5, 1]
    )!
    private static let appWaveColor = CGColor(srgbRed: 0.85, green: 0.35, blue: 0.19, alpha: 1)

    init(levelBox: MeterLevelBox) {
        self.levelBox = levelBox
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else {
            return
        }
        let link = displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = Self.frameRate
        linkUsesReducedRate = false
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion != linkUsesReducedRate {
            linkUsesReducedRate = reduceMotion
            link.preferredFrameRateRange = reduceMotion ? Self.reducedMotionFrameRate : Self.frameRate
        }
        if reduceMotion, let lastDrawTime,
           Date.timeIntervalSinceReferenceDate - lastDrawTime < Self.reducedMotionInterval {
            return
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 0, bounds.height > 0 else {
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let now = Date.timeIntervalSinceReferenceDate
        let deltaTime = lastDrawTime.map { min(max(now - $0, 0), 0.1) } ?? 1.0 / 60.0
        lastDrawTime = now

        let micTarget = WaveBallistics.perceptualLevel(fromRMS: levelBox.mic)
        let appTarget = WaveBallistics.perceptualLevel(fromRMS: levelBox.app)
        let micLevel = CGFloat(reduceMotion ? micTarget : mic.step(target: micTarget, deltaTime: deltaTime))
        let appLevel = CGFloat(reduceMotion ? appTarget : app.step(target: appTarget, deltaTime: deltaTime))

        let phase = reduceMotion ? 0 : now * waveSpeed
        // Never dead-flat while recording: a slow breathing floor
        // signals the session is alive (design D3).
        let breathing: CGFloat = reduceMotion ? 3 : 3 + 1.2 * CGFloat(sin(now * 1.1))
        let micAmplitude = max(micLevel * maxAmplitude, breathing)
        let vivid = 0.35 + 0.65 * micLevel

        if showAppWave {
            let appIntensity = 0.3 + 0.7 * appLevel
            let appAmplitude = max(appLevel * maxAmplitude * 0.9, breathing * 0.6)
            drawLayer(
                into: context,
                amplitude: appAmplitude,
                phase: phase + appWavePhaseOffset,
                color: Self.appWaveColor,
                strokeOpacity: 0.4 * appIntensity,
                fillOpacity: 0.1 * appIntensity
            )
        }

        for layer in Self.micLayers {
            drawLayer(
                into: context,
                amplitude: micAmplitude * layer.amplitudeMultiplier,
                phase: phase + layer.phaseOffset,
                color: nil,
                strokeOpacity: layer.strokeOpacity * vivid,
                fillOpacity: layer.fillOpacity * vivid
            )
        }
    }

    /// Fills and strokes one wave, in `color` or, when nil, the mic gradient.
    private func drawLayer(
        into context: CGContext,
        amplitude: CGFloat,
        phase: Double,
        color: CGColor?,
        strokeOpacity: CGFloat,
        fillOpacity: CGFloat
    ) {
        let path = CGMutablePath()
        path.addLines(between: WaveShape.outline(in: bounds.size, amplitude: amplitude, phase: phase))
        path.closeSubpath()
        let stroke = path.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 10)

        for (shape, opacity) in [(path as CGPath, fillOpacity), (stroke, strokeOpacity)] {
            context.saveGState()
            context.setAlpha(opacity)
            context.addPath(shape)
            if let color {
                context.setFillColor(color)
                context.fillPath()
            } else {
                context.clip()
                context.drawLinearGradient(
                    Self.micGradient,
                    start: .zero,
                    end: CGPoint(x: bounds.width, y: 0),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            context.restoreGState()
        }
    }
}

/// The wave's geometry, apart from the view so it can be checked without drawing.
enum WaveShape {
    private static let step: CGFloat = 2

    /// Points of a closed outline from the midline through the windowed wave back to the midline,
    /// so it both fills cleanly and pins to the center at the edges (design D3).
    static func outline(in size: CGSize, amplitude: CGFloat, phase: Double) -> [CGPoint] {
        let width = max(size.width, 1)
        let midY = size.height / 2
        var points = [CGPoint(x: 0, y: midY)]

        var x: CGFloat = 0
        while x <= width {
            let ratio = Double(x / width)
            let window = pow(sin(.pi * ratio), 0.8)
            let y = midY + amplitude * CGFloat(window * organicWave(ratio: ratio, phase: phase))
            points.append(CGPoint(x: x, y: y))
            x += step
        }

        points.append(CGPoint(x: width, y: midY))
        return points
    }

    private static func organicWave(ratio: Double, phase: Double) -> Double {
        let component1 = sin((4 * Double.pi * ratio) + phase)
        let component2 = 0.4 * sin((7 * Double.pi * ratio) + (1.3 * phase))
        let component3 = 0.3 * sin((2.5 * Double.pi * ratio) + (0.7 * phase))
        return (component1 + component2 + component3) / 1.7
    }
}

/// Latest audio levels, written by the recording monitor and read by the wave when it draws. A
/// plain reference type so writes reach the drawing without SwiftUI invalidation.
final class MeterLevelBox {
    var mic: Float = 0
    var app: Float = 0
}
