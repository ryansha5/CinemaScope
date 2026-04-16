import SwiftUI

// MARK: - DetailFocus
//
// Focus identifiers for the Detail screen action buttons.
// Defined at file level so DetailCTASection can own its own @FocusState.

enum DetailFocus { case play, restart, trailer, favorite }

// MARK: - DetailCTASection
//
// Action button row (Play / Restart / Trailer / Favorite / Back) plus
// the next-episode context line and resume-position hint below it.
// Owns its own @FocusState — no binding needed from the parent.
// Extracted from DetailView (PASS 3). No logic changes.

struct DetailCTASection: View {
    let displayItem:      EmbyItem
    let nextEpisode:      EmbyItem?
    let cta:              PlaybackCTA
    @Binding var isFavorited: Bool
    let hasTrailer:       Bool
    let trailer:          TMDBVideo?
    let scopeMode:        Bool
    let colorMode:        ColorMode
    let onPlay:           (EmbyItem) -> Void
    let onRestart:        (EmbyItem) -> Void
    let onToggleFavorite: (EmbyItem) async -> Void
    let onBack:           () -> Void

    @FocusState private var focusedButton: DetailFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {

                // ── Series: primary CTA is "Continue" / "Play" for the next episode ──
                if displayItem.type == "Series", let next = nextEpisode {
                    let nextCTA   = PlaybackCTA.state(for: next)
                    let playLabel = nextCTA.showsRestart ? "Continue" : "Play"
                    DetailActionButton(icon: "play.fill", label: playLabel,
                        style: .primary, scopeMode: scopeMode, isFocused: focusedButton == .play,
                        colorMode: colorMode) { onPlay(next) }
                    .focused($focusedButton, equals: .play)

                } else {
                    // ── Movie / Episode: standard Play / Resume ──
                    DetailActionButton(icon: "play.fill", label: cta.showsRestart ? "Resume" : "Play",
                        style: .primary, scopeMode: scopeMode, isFocused: focusedButton == .play,
                        colorMode: colorMode) { onPlay(displayItem) }
                    .focused($focusedButton, equals: .play)

                    if cta.showsRestart {
                        DetailActionButton(icon: "arrow.counterclockwise", label: "Restart",
                            style: .secondary, scopeMode: scopeMode, isFocused: focusedButton == .restart,
                            colorMode: colorMode) { onRestart(displayItem) }
                        .focused($focusedButton, equals: .restart)
                    }
                }

                if hasTrailer, let trailer {
                    DetailActionButton(icon: "play.rectangle", label: "Trailer",
                        style: .secondary, scopeMode: scopeMode, isFocused: focusedButton == .trailer,
                        colorMode: colorMode) { openTrailer(trailer) }
                    .focused($focusedButton, equals: .trailer)
                }

                // ── Favorite toggle ──
                DetailActionButton(
                    icon: isFavorited ? "heart.fill" : "heart",
                    label: isFavorited ? "Unfavorite" : "Favorite",
                    style: .secondary,
                    scopeMode: scopeMode,
                    isFocused: focusedButton == .favorite,
                    colorMode: colorMode
                ) {
                    isFavorited.toggle()
                    Task { await onToggleFavorite(displayItem) }
                }
                .focused($focusedButton, equals: .favorite)

                BackButton(colorMode: colorMode, scopeMode: scopeMode, onTap: onBack)
            }
            .onAppear { focusedButton = .play }

            // ── Next episode context line for Series ──
            if displayItem.type == "Series", let next = nextEpisode {
                let s  = next.parentIndexNumber.map { "S\($0)" } ?? ""
                let e  = next.indexNumber.map      { "E\($0)" } ?? ""
                let se = [s, e].filter { !$0.isEmpty }.joined(separator: "·")
                Text("\(se.isEmpty ? "" : "\(se)  —  ")\(next.name)")
                    .font(.system(size: scopeMode ? 12 : 14))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    .lineLimit(1)
            }

            // ── Resume position hint for movies / episodes ──
            if displayItem.type != "Series", let label = cta.resumeLabel {
                Text(label)
                    .font(.system(size: scopeMode ? 12 : 14))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
            }
        }
    }

    // MARK: - Trailer

    private func openTrailer(_ trailer: TMDBVideo) {
        let appURL = URL(string: "youtube://\(trailer.key)")
        let webURL = URL(string: "https://www.youtube.com/watch?v=\(trailer.key)")
        if let appURL, UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else if let webURL {
            UIApplication.shared.open(webURL)
        }
    }
}
