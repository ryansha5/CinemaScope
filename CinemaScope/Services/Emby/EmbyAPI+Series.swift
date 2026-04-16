import Foundation

// MARK: - Series / Episodes

extension EmbyAPI {

    // MARK: - Seasons

    static func fetchSeasons(
        server: EmbyServer, userId: String, token: String, seriesId: String
    ) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Shows/\(seriesId)/Seasons")
        comps.queryItems = [
            .init(name: "UserId",            value: userId),
            .init(name: "Fields",            value: "PrimaryImageAspectRatio,UserData,ChildCount"),
            .init(name: "ImageTypeLimit",    value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }

    // MARK: - Episodes for a season

    static func fetchEpisodes(
        server: EmbyServer, userId: String, token: String,
        seriesId: String, seasonId: String
    ) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Shows/\(seriesId)/Episodes")
        comps.queryItems = [
            .init(name: "UserId",            value: userId),
            .init(name: "SeasonId",          value: seasonId),
            .init(name: "Fields",            value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,BackdropImageTags"),
            .init(name: "ImageTypeLimit",    value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }

    // MARK: - Next Up
    // Returns the next unwatched episode for each series the user has started.
    // Emby's /Shows/NextUp endpoint is purpose-built for this use case.

    static func fetchNextUp(
        server: EmbyServer, userId: String, token: String, limit: Int = 25
    ) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Shows/NextUp")
        comps.queryItems = [
            .init(name: "UserId",                value: userId),
            .init(name: "Limit",                 value: "\(limit)"),
            .init(name: "Fields",                value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,BackdropImageTags,SeriesId,SeriesName"),
            .init(name: "ImageTypeLimit",        value: "1"),
            .init(name: "EnableImageTypes",      value: "Primary,Thumb,Backdrop"),
            .init(name: "EnableTotalRecordCount", value: "false"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }

    // MARK: - All episodes for a series (for continue watching context)

    static func fetchAllEpisodes(
        server: EmbyServer, userId: String, token: String, seriesId: String
    ) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Shows/\(seriesId)/Episodes")
        comps.queryItems = [
            .init(name: "UserId",            value: userId),
            .init(name: "Fields",            value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData"),
            .init(name: "ImageTypeLimit",    value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }
}
