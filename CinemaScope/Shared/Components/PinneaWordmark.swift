import SwiftUI

// MARK: - PinneaWordmark
//
// Brand logotype in Apple's New York serif (system .serif design).
// SwiftUI's Font.system(size:weight:design:.serif) automatically selects
// the correct New York optical size for the given point size.
//
// Dark mode  → glistening gold with a continuous highlight sweep.
// Light mode → solid peacock blue, no shimmer.

struct PinneaWordmark: View {

    let colorMode: ColorMode
    /// Point size — caller decides context (nav bar, splash, etc.)
    let fontSize:  CGFloat

    @State private var shimmerX: CGFloat = -0.3  // multiplier of view width

    private var wordmarkFont: Font {
        .system(size: fontSize, weight: .regular, design: .serif)
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .center) {
            // Solid base — gold (dark) or peacock (light)
            Text("PINEA")
                .font(wordmarkFont)
                .foregroundStyle(baseColor)

            // Shimmer sweep overlay (dark mode only)
            if colorMode == .dark {
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear,                     location: 0.00),
                            .init(color: Color.white.opacity(0.88),  location: 0.50),
                            .init(color: .clear,                     location: 1.00),
                        ],
                        startPoint: .leading,
                        endPoint:   .trailing
                    )
                    // Band width ≈ 45 % of the word — wide enough to feel liquid
                    .frame(width: geo.size.width * 0.45, height: geo.size.height)
                    .offset(x: shimmerX * geo.size.width)
                    .blendMode(.screen)   // brightens gold rather than replacing it
                }
                // Clip the shimmer to the exact text silhouette
                .mask(alignment: .center) {
                    Text("PINEA").font(wordmarkFont)
                }
            }
        }
        .fixedSize()   // prevent GeometryReader from stretching the wordmark
        .onAppear {
            guard colorMode == .dark else { return }
            // Sweep from 30 % off-screen left to 30 % past right, then loop
            withAnimation(
                .linear(duration: 2.4)
                .delay(0.8)
                .repeatForever(autoreverses: false)
            ) {
                shimmerX = 1.3
            }
        }
    }

    // MARK: - Helpers

    private var baseColor: Color {
        colorMode == .dark ? CinemaTheme.gold : CinemaTheme.peacock
    }
}
