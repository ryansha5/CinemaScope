import SwiftUI

// MARK: - SplashView
//
// Full-screen intro that plays once on every cold launch.
// Total duration ≈ 6 seconds (caller fades it out after 5.6 s).
//
// Animation:
//   • Always uses the dark peacock background, regardless of user colour mode.
//   • "PINEA" in Apple's New York serif (Font.system design: .serif).
//   • Letters pop in one at a time with a spring bounce that overshoots and settles.
//   • After all letters land, a gold highlight sweeps the word continuously.
//
// Timing:
//   • First letter appears at t ≈ 0.35 s
//   • Last  letter appears at t ≈ 1.75 s  (4 × 0.35 s gap, 5 letters)
//   • Shimmer starts         at t ≈ 2.40 s (letters fully at rest)
//   • Caller fades view out  at t ≈ 5.60 s → invisible by t ≈ 6.20 s

struct SplashView: View {

    // One Bool per letter — drives the entrance spring
    @State private var visible: [Bool] = Array(repeating: false, count: 5)
    // Shimmer band x-position expressed as a multiplier of the wordmark width
    @State private var shimmerX: CGFloat = -0.30

    private let letters:  [String]  = Array("PINEA").map(String.init)
    private let stagger:  Double    = 0.35   // seconds between letters
    private let spring:   Animation = .spring(response: 0.50, dampingFraction: 0.52)

    // Large display size — fills the screen comfortably on 1080 p tvOS
    private let fontSize: CGFloat = 168
    private var letterFont: Font {
        .system(size: fontSize, weight: .regular, design: .serif)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            background
            wordmarkStack
        }
        .ignoresSafeArea()
        .onAppear { startSequence() }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            // Core dark peacock gradient — same as dark UI background
            CinemaTheme.backgroundGradient(.dark)
            // Radial teal bloom centred slightly right — gives depth
            CinemaTheme.radialOverlay(.dark)
        }
        .ignoresSafeArea()
    }

    // MARK: - Wordmark stack

    private var wordmarkStack: some View {
        ZStack(alignment: .center) {
            // ── Visible letters ──────────────────────────────────────────────
            HStack(spacing: 18) {
                ForEach(letters.indices, id: \.self) { i in
                    Text(letters[i])
                        .font(letterFont)
                        .foregroundStyle(CinemaTheme.gold)
                        // Entrance spring: hop up from below, overshoot, settle
                        .offset(y: visible[i] ? 0 : 96)
                        .opacity(visible[i] ? 1 : 0)
                        .scaleEffect(visible[i] ? 1.0 : 0.32, anchor: .bottom)
                }
            }

            // ── Shimmer band (added once all letters are visible) ────────────
            // The band sweeps once every ~2.4 s, looping continuously.
            shimmerBand
        }
    }

    // MARK: - Shimmer band
    //
    // A bright highlight strip that travels across the gold text, masked
    // to the letter silhouettes so it only glints inside the characters.

    private var shimmerBand: some View {
        GeometryReader { geo in
            let bandW = geo.size.width * 0.42
            LinearGradient(
                stops: [
                    .init(color: .clear,                     location: 0.00),
                    .init(color: Color.white.opacity(0.92),  location: 0.50),
                    .init(color: .clear,                     location: 1.00),
                ],
                startPoint: .leading,
                endPoint:   .trailing
            )
            .frame(width: bandW, height: geo.size.height)
            // shimmerX = -0.30 → band starts 30 % off left edge
            // shimmerX =  1.30 → band finishes 30 % past right edge
            .offset(x: shimmerX * geo.size.width)
            .blendMode(.screen)   // adds brightness to gold without washing it out
        }
        // Clip the shimmer so it only shows through the letter shapes
        .mask(alignment: .center) {
            HStack(spacing: 18) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter).font(letterFont)
                }
            }
        }
    }

    // MARK: - Animation sequence

    private func startSequence() {
        // 1. Stagger each letter's spring entrance
        for i in letters.indices {
            let delay = 0.30 + Double(i) * stagger
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(spring) {
                    visible[i] = true
                }
            }
        }

        // 2. Start the shimmer sweep after all letters have fully settled
        //    Last letter fires at 0.30 + 4*0.35 = 1.70 s; add 0.55 s for spring to finish
        let shimmerStart = 0.30 + Double(letters.count - 1) * stagger + 0.55
        DispatchQueue.main.asyncAfter(deadline: .now() + shimmerStart) {
            withAnimation(
                .linear(duration: 2.4)
                .repeatForever(autoreverses: false)
            ) {
                shimmerX = 1.30
            }
        }
    }
}
