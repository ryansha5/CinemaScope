import SwiftUI

// MARK: - SplashView
//
// Full-screen intro that plays once on every cold launch.
// Total duration ≈ 6 seconds (caller fades it out after 5.6 s).
//
// Animation:
//   • Pinecone image fades in first (easeIn, 0.8 s)
//   • "PINEA" letters pop in one at a time with a spring bounce (original)
//   • After all letters land, a gold highlight sweeps the word continuously
//
// Timing:
//   • Pinecone appears  at t ≈ 0.00 s (fades in over 0.8 s)
//   • First letter      at t ≈ 0.35 s
//   • Last  letter      at t ≈ 1.75 s  (4 × 0.35 s gap, 5 letters)
//   • Shimmer starts    at t ≈ 2.40 s (letters fully at rest)
//   • Caller fades out  at t ≈ 5.60 s → invisible by t ≈ 6.20 s

struct SplashView: View {

    // One Bool per letter — drives the entrance spring
    @State private var visible: [Bool] = Array(repeating: false, count: 5)
    // Shimmer band x-position expressed as a multiplier of the wordmark width
    @State private var shimmerX: CGFloat = -0.30
    // Pinecone fade-in
    @State private var imageVisible: Bool = false

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

            VStack(spacing: 36) {
                Spacer()

                // ── Pinecone image ───────────────────────────────────────────
                Image("pinea_pinecone")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 356)  // 187.5 % of original 190
                    .shadow(
                        color: Color(red: 1.0, green: 0.78, blue: 0.35).opacity(0.40),
                        radius: 24, x: 0, y: 6
                    )
                    .shadow(
                        color: Color(red: 1.0, green: 0.65, blue: 0.20).opacity(0.18),
                        radius: 64, x: 0, y: 0
                    )
                    .opacity(imageVisible ? 1 : 0)
                    .animation(.easeIn(duration: 0.8), value: imageVisible)

                // ── Original wordmark stack ──────────────────────────────────
                // .fixedSize() stops the inner GeometryReader (shimmer band) from
                // inflating the ZStack to full screen height, which was pushing the
                // pinecone to the top and creating the large gap.
                wordmarkStack
                    .fixedSize()

                Spacer()
            }
        }
        .ignoresSafeArea()
        .onAppear { startSequence() }
    }

    // MARK: - Background (original, unchanged)

    private var background: some View {
        ZStack {
            CinemaTheme.backgroundGradient(.dark)
            CinemaTheme.radialOverlay(.dark)
        }
        .ignoresSafeArea()
    }

    // MARK: - Wordmark stack (original, unchanged)

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

            // ── Shimmer band ─────────────────────────────────────────────────
            shimmerBand
        }
    }

    // MARK: - Shimmer band (original, unchanged)

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
            .offset(x: shimmerX * geo.size.width)
            .blendMode(.screen)
        }
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
        // 0. Pinecone fades in immediately
        imageVisible = true

        // 1. Stagger each letter's spring entrance (original timing)
        for i in letters.indices {
            let delay = 0.30 + Double(i) * stagger
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(spring) {
                    visible[i] = true
                }
            }
        }

        // 2. Start the shimmer sweep after all letters have fully settled
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
