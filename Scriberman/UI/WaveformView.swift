import SwiftUI

struct WaveformView: View {
    @Binding var level: Float

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<22, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor.opacity(0.25 + (Double(index) / 40.0)))
                    .frame(width: 6, height: barHeight(for: index))
                    .animation(.easeInOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 72)
        .padding(.horizontal, 4)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalizedLevel = max(0, min(1, CGFloat(level)))
        let spread = abs(CGFloat(index - 11)) / 11
        let emphasis = max(0.18, 1 - (spread * 0.8))
        return 12 + (60 * normalizedLevel * emphasis)
    }
}
