import SwiftUI

// MARK: - HyperBackdropPanel
//
// Full-screen decorative overlay rendered above the nav bar when the user
// browses a "hyper" ribbon (any ribbon below Recommendations).
//
// No focusable elements — allowsHitTesting(false) lets focus pass through.
// A bottom-fade mask dissolves the panel into the teal CinemaBackground so
// there is no hard line; the ribbon appears to sit in the app's own bg.

struct HyperBackdropPanel: View {

    let item:      EmbyItem
    let ribbon:    HomeRibbon
    let session:   EmbySession
    let colorMode: ColorMode

    @EnvironmentObject var settings: AppSettings

    // MARK: - Image URL

    private var backdropURL: URL? {
        guard let server = session.server else { return nil }
        if let tag = item.backdropImageTags?.first {
            return EmbyAPI.backdropImageURL(server: server, itemId: item.id, tag: tag, width: 1920)
        }
        if let tag = item.imageTags?.thumb {
            return EmbyAPI.thumbImageURL(server: server, itemId: item.id, tag: tag, width: 1920)
        }
        if let tag = item.imageTags?.primary {
            return EmbyAPI.primaryImageURL(server: server, itemId: item.id, tag: tag, width: 1920)
        }
        return nil
    }

    // MARK: - Metadata

    private var metaLine: String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if let r    = item.officialRating { parts.append(r) }
        if let rt   = item.runTimeTicks   { parts.append(formatRuntime(rt)) }
        if let r    = item.communityRating { parts.append(String(format: "★ %.1f", r)) }
        return parts.joined(separator: "  ·  ")
    }

    private func formatRuntime(_ ticks: Int64) -> String {
        let minutes = Int(ticks / 600_000_000)
        let h = minutes / 60; let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private var displayTitle: String {
        item.type == "Episode" ? (item.seriesName ?? item.name) : item.name
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {

                // ── Backdrop artwork (fills full panel) ───────────────────────
                Group {
                    if let url = backdropURL {
                        CachedAsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { Color.clear }
                    } else {
                        CinemaTheme.backgroundGradient(colorMode)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

                // ── Left-side legibility scrim ────────────────────────────────
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.80), location: 0.00),
                        .init(color: .black.opacity(0.40), location: 0.40),
                        .init(color: .clear,               location: 0.68),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geo.size.width, height: geo.size.height)

                // ── Metadata (ribbon label, title, meta, genres, overview) ────
                // Positioned in the upper portion of the panel so it stays
                // well within the opaque zone of the bottom-fade mask.
                VStack(alignment: .leading, spacing: 10) {
                    Text(ribbon.type.displayName.uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CinemaTheme.peacockLight.opacity(0.75))
                        .tracking(2)

                    Text(displayTitle)
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.55), radius: 10, x: 0, y: 3)

                    if !metaLine.isEmpty {
                        Text(metaLine)
                            .font(.system(size: 17))
                            .foregroundStyle(.white.opacity(0.65))
                    }

                    if let genres = item.genres, !genres.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(genres.prefix(4), id: \.self) { genre in
                                Text(genre)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                                    }
                            }
                        }
                    }

                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.50))
                            .lineLimit(3)
                            .lineSpacing(4)
                            .frame(maxWidth: 680, alignment: .leading)
                    }
                }
                .padding(.top, 110)     // clear the nav bar / top safe area
                .padding(.horizontal, 64)
            }
        }
        // Fade to transparent at the bottom so the teal CinemaBackground
        // shows through — ribbon cards appear below the transparent zone.
        // Starts fading at ~33 % and is fully clear by ~52 %.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.00),   // fully opaque at top
                    .init(color: .black, location: 0.33),   // stays opaque through metadata
                    .init(color: .clear, location: 0.52),   // fully transparent — cards show here
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }
}
