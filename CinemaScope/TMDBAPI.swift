import Foundation

// MARK: - TMDB API

enum TMDBAPI {

    private static let apiKey  = "73de12bdeaca170722b4da649a493050"
    private static let baseURL = "https://api.themoviedb.org/3"

    // MARK: - Fetch by TMDB ID (preferred — use when Emby provides the ID)

    static func fetchMovie(tmdbId: Int) async throws -> TMDBMetadata {
        let url = try makeURL("/movie/\(tmdbId)", params: [
            "api_key":            apiKey,
            "append_to_response": "credits,videos,keywords",
        ])
        let movie: TMDBMovieDetail = try await fetch(url)
        return .from(movie: movie)
    }

    static func fetchTV(tmdbId: Int) async throws -> TMDBMetadata {
        let url = try makeURL("/tv/\(tmdbId)", params: [
            "api_key":            apiKey,
            "append_to_response": "credits,videos,keywords",
        ])
        let tv: TMDBTVDetail = try await fetch(url)
        return .from(tv: tv)
    }

    // MARK: - Search (fallback when no TMDB ID available)

    static func searchMovie(title: String, year: Int?) async throws -> TMDBMetadata? {
        var params: [String: String] = ["api_key": apiKey, "query": title, "include_adult": "false"]
        if let year { params["year"] = "\(year)" }
        let url = try makeURL("/search/movie", params: params)
        let results: TMDBSearchResults = try await fetch(url)
        guard let first = results.results?.first else { return nil }
        return try await fetchMovie(tmdbId: first.id)
    }

    static func searchTV(title: String, year: Int?) async throws -> TMDBMetadata? {
        var params: [String: String] = ["api_key": apiKey, "query": title]
        if let year { params["first_air_date_year"] = "\(year)" }
        let url = try makeURL("/search/tv", params: params)
        let results: TMDBSearchResults = try await fetch(url)
        guard let first = results.results?.first else { return nil }
        return try await fetchTV(tmdbId: first.id)
    }

    // MARK: - Main entry point — called from DetailView
    // Tries TMDB ID from Emby provider IDs first, falls back to search.

    static func metadata(for item: EmbyItem) async -> TMDBMetadata? {
        let isTV = item.type == "Series"

        // 1. Try TMDB ID from Emby's ProviderIds
        if let tmdbId = item.tmdbId {
            return try? await (isTV ? fetchTV(tmdbId: tmdbId) : fetchMovie(tmdbId: tmdbId))
        }

        // 2. Fall back to title + year search
        let year = item.productionYear
        if isTV {
            return try? await searchTV(title: item.name, year: year)
        } else {
            return try? await searchMovie(title: item.name, year: year)
        }
    }

    // MARK: - Helpers

    private static func makeURL(_ path: String, params: [String: String]) throws -> URL {
        var comps = URLComponents(string: baseURL + path)!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw URLError(.badURL) }
        return url
    }

    private static func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
