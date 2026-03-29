import SwiftUI

struct SkeletonView: View {
    @State private var shimmerOffset: CGFloat = -1.2

    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.secondary.opacity(0.18))
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.white.opacity(0.35),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.55)
                    .offset(x: proxy.size.width * shimmerOffset)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    shimmerOffset = 1.2
                }
            }
    }
}
