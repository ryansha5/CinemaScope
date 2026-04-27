import Foundation

// MARK: - Recommendations
//
// Multi-seed personalized recommendations.
// Seeds come from recently-watched Movies AND Series (by DatePlayed).
// Each result is paired with the seed that generated it for "Because you watched X" UI.
// Filters: not already played, not Christmas content, not a seed item itself.

extension EmbyAPI {

    static func fetchPersonalizedRecommendations(
        server: EmbyServer,
        userId: String,
        token: String,
        limit: Int = 20
    ) async throws -> [RecommendationItem] {

        // 1. Fetch the 10 most-recently-watched Movies + Series as seeds
        var recentComps = try urlComponents(server, path: "/Users/\(userId)/Items")
        recentComps.queryItems = [
            .init(name: "SortBy",           value: "DatePlayed"),
            .init(name: "SortOrder",        value: "Descending"),
            .init(name: "Filters",          value: "IsPlayed"),
            .init(name: "IncludeItemTypes", value: "Movie,Series"),
            .init(name: "Recursive",        value: "true"),
            .init(name: "Limit",            value: "10"),
            .init(name: "Fields",           value: "Genres,UserData"),
            .init(name: "ImageTypeLimit",   value: "1"),
            .init(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop"),
        ]
        guard let recentURL = recentComps.url else { throw EmbyError.invalidURL }
        let recentlyWatched = try decode(EmbyItemsResponse.self,
                                         from: try await get(url: recentURL, token: token)).items

        guard !recentlyWatched.isEmpty else { return [] }

        // Pre-populate seen set with all seed IDs so seeds never appear as recommendations
        var seenIds = Set(recentlyWatched.map(\.id))
        var results: [RecommendationItem] = []

        // Shuffle seeds so the row varies across sessions
        for seed in recentlyWatched.shuffled() {
            guard results.count < limit else { break }

            var simComps = try urlComponents(server, path: "/Items/\(seed.id)/Similar")
            simComps.queryItems = [
                .init(name: "UserId",           value: userId),
                .init(name: "Limit",            value: "8"),
                .init(name: "Fields",           value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,Genres,BackdropImageTags,OfficialRating,CommunityRating,Taglines,People"),
                .init(name: "ImageTypeLimit",   value: "1"),
                .init(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop"),
            ]
            guard let simURL = simComps.url else { continue }

            let similars = (try? decode(EmbyItemsResponse.self,
                                        from: try await get(url: simURL, token: token)).items) ?? []

            // Take up to 2 per seed — gives better coverage on small libraries
            var takenFromSeed = 0
            for candidate in similars {
                guard results.count < limit          else { break }
                guard takenFromSeed < 2              else { break }
                guard !seenIds.contains(candidate.id) else { continue }
                guard !candidate.isChristmasContent   else { continue }
                guard candidate.userData?.played != true else { continue }  // skip already-watched
                seenIds.insert(candidate.id)
                results.append(RecommendationItem(id: candidate.id, recommendation: candidate, becauseOf: seed))
                takenFromSeed += 1
            }
        }

        // Final shuffle so seed groupings aren't visible to the user
        return results.shuffled()
    }
}
