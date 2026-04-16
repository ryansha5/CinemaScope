import SwiftUI

// MARK: - DetailViewModel
//
// Owns all data-loading state and async fetch logic for the Detail screen.
// DetailView is a pure renderer that observes this ViewModel — no fetch logic lives in the view.
//
// Extracted from DetailView (PASS 2). Behavior is identical; only the home of the logic changed.

@MainActor
final class DetailViewModel: ObservableObject {

    // MARK: - Inputs (set once at init, never change)

    let item:    EmbyItem
    let session: EmbySession

    // MARK: - Published state

    @Published var detail:               EmbyItem?     = nil
    @Published var tmdb:                 TMDBMetadata? = nil
    @Published var mediaInfo:            EmbyMediaSource? = nil
    @Published var collectionItems:      [EmbyItem]    = []
    @Published var seasons:              [EmbyItem]    = []
    @Published var singleSeasonEpisodes: [EmbyItem]    = []   // populated when series has exactly 1 season
    @Published var loadingCollection                   = false
    @Published var selectedSeason:       EmbyItem?     = nil
    // Episode detail — all seasons for the series (drives the season picker in More Episodes)
    @Published var episodeSeasons:       [EmbyItem]    = []
    @Published var selectedEpisodeSeason: EmbyItem?    = nil
    // Collection detail — name of the parent BoxSet (e.g. "Marvel Cinematic Universe")
    @Published var collectionName:       String?       = nil

    @Published var isFavorited: Bool = false

    // MARK: - Init

    init(item: EmbyItem, session: EmbySession) {
        self.item    = item
        self.session = session
    }

    // MARK: - Derived data (computed from published state, no side effects)

    var displayItem: EmbyItem { detail ?? item }

    /// Single source of truth for the Play / Resume / Restart decision.
    var cta: PlaybackCTA { PlaybackCTA.state(for: displayItem) }

    /// Next episode to watch for Series items.
    /// Uses singleSeasonEpisodes (populated for single-season shows).
    /// Returns the first in-progress episode, or the first unwatched one.
    var nextEpisode: EmbyItem? {
        guard displayItem.type == "Series" else { return nil }
        guard !singleSeasonEpisodes.isEmpty else { return nil }
        if let inProgress = singleSeasonEpisodes.first(where: {
            if case .resume = PlaybackCTA.state(for: $0) { return true }
            return false
        }) { return inProgress }
        return singleSeasonEpisodes.first(where: { $0.userData?.played != true })
    }

    var actors: [EmbyPerson] {
        (displayItem.people ?? []).filter { $0.type == "Actor" }
    }
    var directors: [EmbyPerson] {
        (displayItem.people ?? []).filter { $0.type == "Director" }
    }
    var writers: [EmbyPerson] {
        (displayItem.people ?? []).filter { $0.type == "Writer" }
    }
    var hasTrailer: Bool { tmdb?.trailer != nil }

    // MARK: - Load

    func loadAll() async {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }

        // Step 1: Load Emby detail first
        if let loaded = try? await EmbyAPI.fetchItemDetail(
            server: server, userId: user.id, token: token, itemId: item.id) {
            detail = loaded
            isFavorited = loaded.userData?.isFavorite ?? false
        }

        // Step 2a: If this is an episode, load sibling episodes from same season
        //          AND all seasons for the series (for the season picker).
        if (detail?.type ?? item.type) == "Episode" {
            if let seriesId = detail?.seriesId ?? item.seriesId,
               let seasonId = detail?.seasonId ?? item.seasonId {
                loadingCollection = true

                // Load all seasons so the picker above the ribbon is populated
                async let seasonsLoad = EmbyAPI.fetchSeasons(
                    server: server, userId: user.id, token: token, seriesId: seriesId)
                async let episodesLoad = EmbyAPI.fetchEpisodes(
                    server: server, userId: user.id, token: token,
                    seriesId: seriesId, seasonId: seasonId)

                if let fetched = try? await seasonsLoad {
                    episodeSeasons        = fetched
                    selectedEpisodeSeason = fetched.first(where: { $0.id == seasonId })
                }
                if let eps = try? await episodesLoad {
                    // Sort in episode order — the API doesn't guarantee it
                    collectionItems = eps.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
                }
                loadingCollection = false
            }
        }

        // Step 2: Load seasons if this is a Series
        if detail?.type == "Series" || item.type == "Series" {
            let seriesId = detail?.id ?? item.id
            if let fetchedSeasons = try? await EmbyAPI.fetchSeasons(
                server: server, userId: user.id, token: token, seriesId: seriesId) {
                seasons = fetchedSeasons
                selectedSeason = fetchedSeasons.first(where: {
                    ($0.userData?.played ?? false) == false
                }) ?? fetchedSeasons.first

                // Single season — fetch episodes immediately for inline ribbon
                if fetchedSeasons.count == 1, let onlySeason = fetchedSeasons.first {
                    if let eps = try? await EmbyAPI.fetchEpisodes(
                        server: server, userId: user.id, token: token,
                        seriesId: seriesId, seasonId: onlySeason.id) {
                        singleSeasonEpisodes = eps
                    }
                }
            }
        }

        // Step 3: Fetch media technical info
        if let info = try? await EmbyAPI.fetchMediaInfo(
            server: server, userId: user.id, token: token, itemId: detail?.id ?? item.id) {
            mediaInfo = info
        }

        // Step 4: Load collection siblings + collection name for movies/shows.
        // Emby collections are virtual BoxSets — physical parentId / Ancestors won't find them.
        // Strategy: fetch all BoxSets, then fan-out and fetch each one's items in parallel,
        // and keep the first BoxSet whose member list contains the current item.
        let resolvedType = detail?.type ?? item.type
        if resolvedType != "Episode" {
            let currentId = detail?.id ?? item.id
            if let allBoxSets = try? await EmbyAPI.fetchCollections(
                server: server, userId: user.id, token: token),
               !allBoxSets.isEmpty {

                // Fan-out: fetch every BoxSet's items concurrently
                let found: (boxSet: EmbyItem, items: [EmbyItem])? = await withTaskGroup(
                    of: (EmbyItem, [EmbyItem])?.self
                ) { group in
                    for boxSet in allBoxSets {
                        group.addTask {
                            guard let members = try? await EmbyAPI.fetchCollectionItems(
                                server: server, userId: user.id, token: token,
                                collectionId: boxSet.id)
                            else { return nil }
                            return members.contains(where: { $0.id == currentId })
                                ? (boxSet, members)
                                : nil
                        }
                    }
                    for await result in group {
                        if let match = result { return match }
                    }
                    return nil
                }

                if let match = found {
                    loadingCollection = true
                    collectionName  = match.boxSet.name
                    collectionItems = match.items
                    loadingCollection = false
                }
            }
        }

        // Step 5: Enrich with TMDB — run last, failure is non-fatal
        // Use a detached task with timeout so a slow/failed TMDB
        // request never blocks or crashes the detail view
        let enrichItem = detail ?? item
        Task.detached(priority: .background) {
            let metadata = await TMDBAPI.metadata(for: enrichItem)
            await MainActor.run { self.tmdb = metadata }
        }
    }

    // MARK: - Episode season switch

    /// Called when the user picks a different season from the More Episodes season picker.
    func loadEpisodesForSeason(_ season: EmbyItem) async {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }
        guard let seriesId = detail?.seriesId ?? item.seriesId else { return }
        withAnimation(.easeInOut(duration: 0.2)) { loadingCollection = true }
        selectedEpisodeSeason = season
        if let eps = try? await EmbyAPI.fetchEpisodes(
            server: server, userId: user.id, token: token,
            seriesId: seriesId, seasonId: season.id) {
            collectionItems = eps.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
        }
        withAnimation { loadingCollection = false }
    }
}
