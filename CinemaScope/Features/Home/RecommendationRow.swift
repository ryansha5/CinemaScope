import SwiftUI

// MARK: - RecommendationRow
// Large 16:9 cards sized so ~2.5 fit on screen at once.
// Each card shows a recommended movie with a "Because you watched X" attribution line.

struct RecommendationRow: View {
    let title:     String
    let items:     [RecommendationItem]
    let session:   EmbySession
    let scopeMode: Bool
    let colorMode: ColorMode
    let onSelect:  (EmbyItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: scopeMode ? 10 : 16) {
            // Section header
            Text(title)
                .font(scopeMode
                      ? .system(size: 18, weight: .semibold)
                      : .system(size: 24, weight: .semibold))
                .foregroundStyle(CinemaTheme.primary(colorMode))
                .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CinemaTheme.cardSpacing) {
                    ForEach(items) { item in
                        RecommendationCard(
                            item:      item,
                            session:   session,
                            scopeMode: scopeMode,
                            colorMode: colorMode,
                            onSelect:  onSelect
                        )
                    }
                }
                .padding(.horizontal, 4)   // slight inset so focus ring isn't clipped
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
        }
    }
}

// MARK: - RecommendationCard

private struct RecommendationCard: View {

    let item:      RecommendationItem
    let session:   EmbySession
    let scopeMode: Bool
    let colorMode: ColorMode
    let onSelect:  (EmbyItem) -> Void

    // Card dimensions: wide enough that ~2.5 fit on the 1920pt tvOS canvas
    // pagePadding(24) × 2 = 48 overhead; 1872pt usable → 2.5 cards + 1.5 gaps (28pt) ≈ 1872
    // Width = 732, Height = 412 (16:9)
    private let cardWidth:  CGFloat = 732
    private let cardHeight: CGFloat = 412

    @FocusState private var focused: Bool

    var body: some View {
        Button {
            onSelect(item.recommendation)
        } label: {
            ZStack(alignment: .bottomLeading) {
                // ── Backdrop image ──────────────────────────────────────
                backdropImage
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()

                // ── Gradient overlay ────────────────────────────────────
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear,                    location: 0.35),
                        .init(color: Color.black.opacity(0.75), location: 0.72),
                        .init(color: Color.black.opacity(0.95), location: 1.0),
                    ]),
                    startPoint: .top,
                    endPoint:   .bottom
                )
                .frame(width: cardWidth, height: cardHeight)

                // ── Text overlay ────────────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.recommendation.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CinemaTheme.accentGold)
                        Text("Because you watched \(item.becauseOf.name)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(CinemaTheme.accentGold)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Focus ring
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        focused
                            ? CinemaTheme.focusRimGradient(colorMode)
                            : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                        lineWidth: 4
                    )
            )
            .scaleEffect(focused ? 1.05 : 1.0)
            .shadow(
                color: focused ? CinemaTheme.focusAccent(colorMode).opacity(0.55) : Color.black.opacity(0.3),
                radius: focused ? 18 : 8
            )
            .shadow(
                color: focused ? CinemaTheme.focusGlow(colorMode) : .clear,
                radius: focused ? 8 : 0
            )
            .animation(.easeInOut(duration: 0.15), value: focused)
        }
        .focusRingFree()
        .focused($focused)
    }

    // MARK: - Image resolution
    // Priority: backdrop → thumb → primary (poster, cropped to fill)

    @ViewBuilder
    private var backdropImage: some View {
        let w = Int(cardWidth * 2)   // 2× for sharp rendering on 4K TVs

        if let url = backdropURL(width: w) {
            CachedAsyncImage(url: url) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholderView
            }
        } else {
            placeholderView
        }
    }

    private func backdropURL(width: Int) -> URL? {
        guard let server = session.server else { return nil }
        let rec = item.recommendation

        // 1. Backdrop tag on the recommendation itself
        if let tag = rec.backdropImageTags?.first {
            return EmbyAPI.backdropImageURL(server: server, itemId: rec.id, tag: tag, width: width)
        }
        // 2. Thumb tag (still 16:9)
        if let tag = rec.imageTags?.thumb {
            return EmbyAPI.thumbImageURL(server: server, itemId: rec.id, tag: tag, width: width)
        }
        // 3. Primary poster — will be cropped to fill, acceptable fallback
        if let tag = rec.imageTags?.primary {
            return EmbyAPI.primaryImageURL(server: server, itemId: rec.id, tag: tag, width: width)
        }
        return nil
    }

    private var placeholderView: some View {
        let rec = item.recommendation
        return ZStack {
            Color(red: 0.08, green: 0.12, blue: 0.20)
            VStack(spacing: 8) {
                Image(systemName: rec.type == "Series" ? "tv" : "film")
                    .font(.system(size: 36))
                    .foregroundStyle(CinemaTheme.accentGold.opacity(0.4))
                Text(rec.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .lineLimit(2)
            }
        }
    }
}
