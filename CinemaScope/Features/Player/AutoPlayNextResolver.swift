// MARK: - Features / Player / AutoPlayNextResolver
// Sprint 44 — Next-item resolution for auto-play countdown.
//
// Given the item that just finished playing, resolves the next item to
// present in a 5-second countdown overlay inside PlayerLabHostView.
//
// Rules:
//   • Episode → next episode in the series (sorted by season + episode number).
//     When the last episode of the entire series ends, wraps to the very first
//     episode so the series loops rather than dead-ending.
//
//   • Movie that belongs to a BoxSet collection → next movie in that collection
//     (sorted by production year, which matches fetchCollectionItems order).
//     The last movie in a collection returns nil — no wrap.
//
//   • Movie not in any collection → first item from Continue Watching that
//     is not the movie that just played.
//
//   • Any other type (series, boxset, etc.) → nil.

import Foundation

enum AutoPlayNextResolver {

    // MARK: - Public entry point

    /// Returns the next `EmbyItem` to auto-play after `item`, or `nil` if
    /// there is nothing appropriate to follow it.
    static func resolve(
        for item: EmbyItem,
        server: EmbyServer,
        userId: String,
        token: String
    ) async -> EmbyItem? {
        switch item.type {
        case "Episode":
            return await nextEpisode(for: item, server: server, userId: userId, token: token)
        case "Movie":
            return await nextMovie(for: item, server: server, userId: userId, token: token)
        default:
            return nil
        }
    }

    // MARK: - TV Episode

    private static func nextEpisode(
        for episode: EmbyItem,
        server: EmbyServer,
        userId: String,
        token: String
    ) async -> EmbyItem? {
        guard let seriesId = episode.seriesId else { return nil }
        guard let allEpisodes = try? await EmbyAPI.fetchAllEpisodes(
            server: server, userId: userId, token: token, seriesId: seriesId
        ) else { return nil }

        // Sort by season number then episode number for correct series order.
        let sorted = allEpisodes.sorted {
            let s0 = $0.parentIndexNumber ?? 0, s1 = $1.parentIndexNumber ?? 0
            if s0 != s1 { return s0 < s1 }
            return ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0)
        }

        guard let currentIndex = sorted.firstIndex(where: { $0.id == episode.id }) else {
            // Can't locate current episode — fall back to first
            return sorted.first
        }

        let nextIndex = currentIndex + 1
        // Last episode of the series → wrap to the very first episode
        return nextIndex < sorted.count ? sorted[nextIndex] : sorted.first
    }

    // MARK: - Movie

    private static func nextMovie(
        for movie: EmbyItem,
        server: EmbyServer,
        userId: String,
        token: String
    ) async -> EmbyItem? {
        // Prefer collection ordering when the movie belongs to a BoxSet
        if let collection = await collectionAncestor(
            of: movie, server: server, userId: userId, token: token) {
            return await nextInCollection(
                movie, collection: collection,
                server: server, userId: userId, token: token)
        }
        return await nextInContinueWatching(
            after: movie, server: server, userId: userId, token: token)
    }

    private static func collectionAncestor(
        of movie: EmbyItem,
        server: EmbyServer,
        userId: String,
        token: String
    ) async -> EmbyItem? {
        guard let ancestors = try? await EmbyAPI.fetchAncestors(
            server: server, userId: userId, token: token, itemId: movie.id
        ) else { return nil }
        return ancestors.first { $0.type == "BoxSet" }
    }

    private static func nextInCollection(
        _ movie: EmbyItem,
        collection: EmbyItem,
        server: EmbyServer,
        userId: String,
        token: String
    ) async -> EmbyItem? {
        guard let items = try? await EmbyAPI.fetchCollectionItems(
            server: server, userId: userId, token: token, collectionId: collection.id
        ) else { return nil }
        // fetchCollectionItems returns items sorted ProductionYear,SortName ascending —
        // find the current movie and return the one that follows it.
        guard let idx = items.firstIndex(where: { $0.id == movie.id }),
              idx + 1 < items.count else { return nil }
        return items[idx + 1]
    }

    private static func nextInContinueWatching(
        after movie: EmbyItem,
        server: EmbyServer,
        userId: String,
        token: String
    ) async -> EmbyItem? {
        guard let items = try? await EmbyAPI.fetchContinueWatching(
            server: server, userId: userId, token: token, limit: 50
        ) else { return nil }
        // First Continue Watching movie that isn't the one that just ended
        return items.first { $0.id != movie.id && $0.type == "Movie" }
    }
}
