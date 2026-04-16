import SwiftUI

// MARK: - DetailEpisodesSection
//
// Handles all episode/season ribbons for the Detail screen:
//   • Series with 1 season  → inline episode ribbon ("Episodes")
//   • Series with >1 season → season card ribbon ("Seasons")
//   • Episode detail page   → "More Episodes" ribbon with season picker
//
// The parent (DetailView) determines which mode applies via displayItem.type
// and seasons.count, and passes the correct props. The section renders
// whichever ribbon is appropriate.
//
// Extracted from DetailView (PASS 3). No logic changes.

struct DetailEpisodesSection: View {

    // Item whose detail screen is showing
    let displayItem:           EmbyItem
    // Seasons list (Series only)
    let seasons:               [EmbyItem]
    let singleSeasonEpisodes:  [EmbyItem]   // populated when seasons.count == 1
    let selectedSeason:        EmbyItem?
    // Episode-page data
    let collectionItems:       [EmbyItem]   // sibling episodes (Episode detail only)
    let episodeSeasons:        [EmbyItem]   // all seasons for the series (drives picker)
    let selectedEpisodeSeason: EmbyItem?
    let loadingCollection:     Bool
    let session:               EmbySession
    let scopeMode:             Bool
    let colorMode:             ColorMode
    // Callbacks
    let onSeasonTapped:        (EmbyItem) -> Void    // mutates selectedSeason + navigates
    let onNavigate:            (EmbyItem) -> Void    // navigate to episode detail
    let onLoadEpisodes:        (EmbyItem) async -> Void  // season picker selection

    var body: some View {
        if displayItem.type == "Episode" {
            moreEpisodesSection
        } else if seasons.count == 1 && !singleSeasonEpisodes.isEmpty {
            singleSeasonRibbon
        } else if seasons.count > 1 {
            seasonSection
        }
    }

    // MARK: - Single season episode ribbon

    private var singleSeasonRibbon: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Episodes")
                .font(.system(size: scopeMode ? 18 : 22, weight: .semibold))
                .foregroundStyle(CinemaTheme.primary(colorMode))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scopeMode ? 14 : 20) {
                    ForEach(singleSeasonEpisodes) { episode in
                        EpisodeThumbCard(
                            episode:   episode,
                            session:   session,
                            scopeMode: scopeMode,
                            colorMode: colorMode,
                            isCurrent: false
                        ) { onSeasonTapped(seasons[0]) }
                        // Tapping goes to SeasonDetailView so user can
                        // navigate episodes with the full player context
                    }
                }
                .padding(.vertical, 24)
                .padding(.trailing, scopeMode ? 28 : 80)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - Multi-season picker ribbon

    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Seasons")
                .font(.system(size: scopeMode ? 18 : 22, weight: .semibold))
                .foregroundStyle(CinemaTheme.primary(colorMode))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scopeMode ? 16 : 24) {
                    ForEach(seasons) { season in
                        SeasonCard(
                            season:     season,
                            session:    session,
                            scopeMode:  scopeMode,
                            colorMode:  colorMode,
                            isSelected: selectedSeason?.id == season.id
                        ) {
                            onSeasonTapped(season)
                        }
                    }
                }
                .padding(.vertical, 24)
                .padding(.trailing, scopeMode ? 28 : 80)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - More Episodes (episode detail pages)

    private var moreEpisodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {

            // ── Header row: title + season picker ──
            HStack(alignment: .center, spacing: 16) {
                Text("More Episodes")
                    .font(.system(size: scopeMode ? 18 : 22, weight: .semibold))
                    .foregroundStyle(CinemaTheme.primary(colorMode))

                // Season picker — only shown when there are multiple seasons
                if episodeSeasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(episodeSeasons) { season in
                                SeasonPickerPill(
                                    season:     season,
                                    isSelected: selectedEpisodeSeason?.id == season.id,
                                    scopeMode:  scopeMode,
                                    colorMode:  colorMode
                                ) {
                                    guard selectedEpisodeSeason?.id != season.id else { return }
                                    Task { await onLoadEpisodes(season) }
                                }
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            // ── Episode thumb ribbon ──
            // ScrollViewReader lets us jump to the current episode (or ep 1
            // when the user switches to a different season).
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: scopeMode ? 16 : 24) {
                        ForEach(collectionItems.filter { $0.type == "Episode" }) { ep in
                            EpisodeThumbCard(
                                episode:   ep,
                                session:   session,
                                scopeMode: scopeMode,
                                colorMode: colorMode,
                                isCurrent: ep.id == displayItem.id
                            ) { onNavigate(ep) }
                            .id(ep.id)   // anchor for scrollTo
                        }
                    }
                    .padding(.vertical, 24)
                    .padding(.trailing, scopeMode ? 28 : 80)
                }
                .scrollClipDisabled()
                .onAppear {
                    scrollToTarget(in: collectionItems, proxy: proxy)
                }
                // Season switch: collectionItems changes while the view is live
                .onChange(of: collectionItems) { episodes in
                    scrollToTarget(in: episodes, proxy: proxy)
                }
            }
        }
        .opacity(loadingCollection ? 0 : 1)
        .animation(.easeIn(duration: 0.25), value: loadingCollection)
    }

    // MARK: - Scroll helper

    /// Scrolls the ribbon to the current episode, or to ep 1 after a season switch.
    /// The brief delay lets SwiftUI finish layout before scrollTo runs.
    private func scrollToTarget(in episodes: [EmbyItem], proxy: ScrollViewProxy) {
        let episodes = episodes.filter { $0.type == "Episode" }
        let targetId = episodes.first(where: { $0.id == displayItem.id })?.id
                       ?? episodes.first?.id
        guard let targetId else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(targetId, anchor: .center)
            }
        }
    }
}
