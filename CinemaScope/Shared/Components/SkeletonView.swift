import SwiftUI

// MARK: - ShimmerView
//
// A single-direction shimmer gradient that tiles across any shape.
// Embed inside a clip shape to constrain it.

struct ShimmerView: View {
    let colorMode: ColorMode
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                baseColor
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear,       location: 0.0),
                                .init(color: shimmerColor, location: 0.5),
                                .init(color: .clear,       location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint:   .bottomTrailing
                        )
                    )
                    .frame(width: geo.size.width * 0.65)
                    .offset(x: isAnimating
                                ? geo.size.width * 1.4
                                : -geo.size.width * 0.65)
            }
            .clipped()
        }
        .onAppear {
            guard !isAnimating else { return }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }

    private var baseColor:    Color { colorMode == .dark ? .white.opacity(0.09) : .black.opacity(0.06) }
    private var shimmerColor: Color { colorMode == .dark ? .white.opacity(0.20) : .black.opacity(0.12) }
}

// MARK: - SkeletonBox
//
// Rounded-rect skeleton tile — building block for all skeleton layouts.

struct SkeletonBox: View {
    let width:        CGFloat?      // nil → maxWidth .infinity
    let height:       CGFloat
    let cornerRadius: CGFloat
    let colorMode:    ColorMode

    init(width: CGFloat? = nil, height: CGFloat, cornerRadius: CGFloat = 6, colorMode: ColorMode) {
        self.width        = width
        self.height       = height
        self.cornerRadius = cornerRadius
        self.colorMode    = colorMode
    }

    var body: some View {
        // Split into two .frame() calls — SwiftUI won't accept width: and maxWidth:
        // in the same call because they belong to different overloads.
        ShimmerView(colorMode: colorMode)
            .frame(width: width, height: height)            // fixed dims (nil = unconstrained)
            .frame(maxWidth: width == nil ? .infinity : nil) // expand to fill when width was nil
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - SkeletonMediaCard
//
// Matches MediaCard (poster / wide / thumb) for home ribbons.

struct SkeletonMediaCard: View {
    let cardSize:  CardSize
    let scopeMode: Bool
    let colorMode: ColorMode

    private var cardWidth: CGFloat {
        scopeMode
            ? (cardSize == .poster ? CinemaTheme.scopeCardWidth  : 240)
            : (cardSize == .poster ? CinemaTheme.standardCardWidth : 320)
    }
    private var cardHeight: CGFloat {
        switch (cardSize, scopeMode) {
        case (.poster, false): return CinemaTheme.standardCardHeight
        case (.poster, true):  return CinemaTheme.scopeCardHeight
        case (.wide,   false): return 180
        case (.wide,   true):  return 124
        case (.thumb,  false): return 203
        case (.thumb,  true):  return 141
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scopeMode ? 6 : 10) {
            SkeletonBox(width: cardWidth, height: cardHeight,
                       cornerRadius: 8, colorMode: colorMode)

            SkeletonBox(width: cardWidth * 0.72, height: scopeMode ? 12 : 16,
                       cornerRadius: 4, colorMode: colorMode)
            SkeletonBox(width: cardWidth * 0.42, height: scopeMode ? 10 : 13,
                       cornerRadius: 4, colorMode: colorMode)
        }
    }
}

// MARK: - SkeletonRow
//
// A complete shimmering horizontal row that mimics MediaRow.

struct SkeletonRow: View {
    let title:     String
    let cardSize:  CardSize
    let count:     Int
    let scopeMode: Bool
    let colorMode: ColorMode

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaTheme.sectionSpacing) {
            Text(title)
                .font(scopeMode ? .system(size: 20, weight: .semibold) : CinemaTheme.sectionFont)
                .foregroundStyle(CinemaTheme.secondary(colorMode))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scopeMode ? 20 : CinemaTheme.cardSpacing) {
                    ForEach(0..<count, id: \.self) { _ in
                        SkeletonMediaCard(cardSize: cardSize, scopeMode: scopeMode, colorMode: colorMode)
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 4)
            }
            .scrollClipDisabled()
        }
    }
}

// MARK: - SkeletonGridCard
//
// Fills whatever width a LazyVGrid column provides; uses 2:3 aspect ratio.

struct SkeletonGridCard: View {
    let scopeMode: Bool
    let colorMode: ColorMode

    var body: some View {
        VStack(alignment: .leading, spacing: scopeMode ? 6 : 10) {
            // Poster image placeholder — fills column width at 2:3
            GeometryReader { geo in
                ShimmerView(colorMode: colorMode)
                    .frame(width: geo.size.width, height: geo.size.width * 3 / 2)
                    .clipShape(RoundedRectangle(cornerRadius: scopeMode ? 6 : 10))
            }
            .aspectRatio(2/3, contentMode: .fit)

            // Text line skeletons
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 4) {
                    SkeletonBox(width: geo.size.width * 0.76,
                               height: scopeMode ? 10 : 14,
                               cornerRadius: 3, colorMode: colorMode)
                    SkeletonBox(width: geo.size.width * 0.46,
                               height: scopeMode ? 8  : 11,
                               cornerRadius: 3, colorMode: colorMode)
                }
            }
            .frame(height: scopeMode ? 26 : 33)
        }
    }
}

// MARK: - SkeletonDetailHero
//
// Shown in DetailView while the enriched item + TMDB data loads.
// Mirrors the layout of heroRow + overview.

struct SkeletonDetailHero: View {
    let scopeMode: Bool
    let colorMode: ColorMode

    var body: some View {
        let pad: CGFloat = scopeMode ? 28 : 80
        VStack(alignment: .leading, spacing: scopeMode ? 24 : 40) {
            HStack(alignment: .bottom, spacing: scopeMode ? 24 : 48) {
                // Poster skeleton
                let pw: CGFloat = scopeMode ? 110 : 200
                let ph: CGFloat = pw * 3 / 2
                SkeletonBox(width: pw, height: ph,
                           cornerRadius: 10, colorMode: colorMode)

                // Title + meta skeleton
                VStack(alignment: .leading, spacing: scopeMode ? 10 : 18) {
                    SkeletonBox(width: scopeMode ? 220 : 380, height: scopeMode ? 32 : 52,
                               cornerRadius: 6, colorMode: colorMode)
                    SkeletonBox(width: scopeMode ? 140 : 240, height: scopeMode ? 14 : 18,
                               cornerRadius: 4, colorMode: colorMode)
                    SkeletonBox(width: scopeMode ?  90 : 160, height: scopeMode ? 12 : 16,
                               cornerRadius: 4, colorMode: colorMode)
                    HStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in
                            SkeletonBox(width: scopeMode ? 60 : 90, height: scopeMode ? 30 : 42,
                                       cornerRadius: 10, colorMode: colorMode)
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer()
            }

            // Overview skeleton
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<(scopeMode ? 3 : 5), id: \.self) { i in
                    SkeletonBox(height: scopeMode ? 13 : 16,
                               cornerRadius: 4, colorMode: colorMode)
                        .padding(.trailing, i == 2 ? 120 : 0)
                }
            }
            .frame(maxWidth: scopeMode ? 560 : 860, alignment: .leading)
        }
        .padding(.horizontal, pad)
    }
}
