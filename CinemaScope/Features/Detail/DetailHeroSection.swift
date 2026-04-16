import SwiftUI

// MARK: - DetailHeroSection
//
// Full hero row: poster thumbnail on the left, title/meta/genre/CTA column on the right.
// Extracted from DetailView (PASS 3). No logic changes.

struct DetailHeroSection: View {
    let displayItem:      EmbyItem
    let session:          EmbySession
    let mediaInfo:        EmbyMediaSource?
    let tmdb:             TMDBMetadata?
    let nextEpisode:      EmbyItem?
    let cta:              PlaybackCTA
    @Binding var isFavorited: Bool
    let hasTrailer:       Bool
    let scopeMode:        Bool
    let colorMode:        ColorMode
    let onPlay:           (EmbyItem) -> Void
    let onRestart:        (EmbyItem) -> Void
    let onToggleFavorite: (EmbyItem) async -> Void
    let onBack:           () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: scopeMode ? 24 : 48) {
            posterView

            VStack(alignment: .leading, spacing: scopeMode ? 10 : 16) {
                titleBlock
                metaBadgeRow
                genrePillsSection
                DetailCTASection(
                    displayItem:      displayItem,
                    nextEpisode:      nextEpisode,
                    cta:              cta,
                    isFavorited:      $isFavorited,
                    hasTrailer:       hasTrailer,
                    trailer:          tmdb?.trailer,
                    scopeMode:        scopeMode,
                    colorMode:        colorMode,
                    onPlay:           onPlay,
                    onRestart:        onRestart,
                    onToggleFavorite: onToggleFavorite,
                    onBack:           onBack
                )
            }

            Spacer()
        }
    }

    // MARK: - Poster

    private var posterView: some View {
        let isEpisode = displayItem.type == "Episode"
        // Episodes use a 16:9 thumbnail; everything else uses a 2:3 portrait poster
        let w: CGFloat = isEpisode
            ? (scopeMode ? 240 : 340)
            : (scopeMode ? 110 : 190)
        let h: CGFloat = isEpisode
            ? w * 9 / 16
            : (scopeMode ? 165 : 285)

        let posterURL: URL? = {
            guard let server = session.server else { return nil }
            if isEpisode {
                // Prefer 16:9 thumb → episode backdrop → portrait primary
                if let tag = displayItem.imageTags?.thumb {
                    return EmbyAPI.thumbImageURL(server: server, itemId: displayItem.id, tag: tag, width: Int(w * 2))
                }
                if let tag = displayItem.backdropImageTags?.first {
                    return EmbyAPI.backdropImageURL(server: server, itemId: displayItem.id, tag: tag, width: Int(w * 2))
                }
            }
            guard let tag = displayItem.imageTags?.primary else { return nil }
            return EmbyAPI.primaryImageURL(server: server, itemId: displayItem.id, tag: tag, width: Int(w * 2))
        }()

        return Group {
            if let url = posterURL {
                CachedAsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10).fill(CinemaTheme.cardGradient(colorMode))
                }
            } else {
                RoundedRectangle(cornerRadius: 10).fill(CinemaTheme.cardGradient(colorMode))
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.55), radius: 28, x: 0, y: 14)
    }

    // MARK: - Title block

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            // For episodes, show series name as a breadcrumb above the title
            if displayItem.type == "Episode", let seriesName = displayItem.seriesName {
                Text(seriesName)
                    .font(.system(size: scopeMode ? 13 : 17, weight: .semibold))
                    .foregroundStyle(CinemaTheme.accentGold.opacity(0.85))
                    .lineLimit(1)
            }
            // Season + episode number line (e.g. "Season 2  ·  Episode 4")
            if displayItem.type == "Episode" {
                let parts: [String] = [
                    displayItem.seasonName,
                    displayItem.indexNumber.map { "Episode \($0)" }
                ].compactMap { $0 }
                if !parts.isEmpty {
                    Text(parts.joined(separator: "  ·  "))
                        .font(.system(size: scopeMode ? 12 : 15, weight: .medium))
                        .foregroundStyle(CinemaTheme.tertiary(colorMode))
                        .lineLimit(1)
                }
            }
            Text(displayItem.name)
                .font(.system(size: scopeMode ? 28 : 46, weight: .bold))
                .foregroundStyle(CinemaTheme.primary(colorMode))
                .lineLimit(2)
            if let tagline = displayItem.taglines?.first, !tagline.isEmpty {
                Text(tagline)
                    .font(.system(size: scopeMode ? 14 : 18))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    .italic().lineLimit(1)
            }
        }
    }

    // MARK: - Meta badge row

    private var metaBadgeRow: some View {
        HStack(spacing: 8) {
            if let year = displayItem.productionYear { badge("\(year)") }
            if let r = displayItem.officialRating    { badge(r) }
            // Runtime for movies/episodes
            if let m = displayItem.runtimeMinutes, displayItem.type != "Series" {
                badge(formatRuntime(m))
            }
            if let s = displayItem.communityRating   { badge(String(format: "★ %.1f", s), gold: true) }
            // Type badge
            switch displayItem.type {
            case "Series":
                badge("Series")
                if let c = displayItem.childCount, c > 0  { badge("\(c) Season\(c == 1 ? "" : "s")") }
                if let e = displayItem.episodeCount, e > 0 { badge("\(e) Episodes") }
            case "Episode":
                badge("Episode")
                if let sn = displayItem.seasonName  { badge(sn) }
                if let ep = displayItem.indexNumber { badge("Ep \(ep)") }
            default:
                badge("Movie")
            }
            // Technical quality badges — resolution and HDR from loaded media info
            if let video = mediaInfo?.videoStream {
                if let res = video.resolutionLabel { badge(res) }
                if let hdr = video.hdrLabel        { badge(hdr, gold: true) }
            }
        }
    }

    private func badge(_ text: String, gold: Bool = false) -> some View {
        Text(text)
            .font(CinemaTheme.captionFont)
            .foregroundStyle(gold ? CinemaTheme.accentGold : CinemaTheme.secondary(colorMode))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                gold ? CinemaTheme.accentGold.opacity(0.15) : CinemaTheme.surfaceNav(colorMode),
                in: RoundedRectangle(cornerRadius: 6)
            )
    }

    // MARK: - Genre pills

    @ViewBuilder
    private var genrePillsSection: some View {
        let genres: [String] = {
            if let g = tmdb?.genres, !g.isEmpty { return g }
            return displayItem.genres ?? []
        }()
        if !genres.isEmpty {
            HStack(spacing: 8) {
                ForEach(genres.prefix(5), id: \.self) { g in
                    Text(g)
                        .font(.system(size: scopeMode ? 12 : 14, weight: .medium))
                        .foregroundStyle(CinemaTheme.accentGold.opacity(0.9))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(CinemaTheme.accentGold.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(CinemaTheme.accentGold.opacity(0.25), lineWidth: 1) }
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatRuntime(_ minutes: Int) -> String {
        let h = minutes / 60; let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
