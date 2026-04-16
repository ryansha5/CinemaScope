import Foundation

// MARK: - Search

extension EmbyAPI {

    static func search(
        server: EmbyServer, userId: String, token: String,
        query: String,
        includeItemTypes: String = "Movie,Series,BoxSet,Playlist",
        limit: Int = 75
    ) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items")
        comps.queryItems = [
            .init(name: "SearchTerm",       value: query),
            .init(name: "IncludeItemTypes", value: includeItemTypes),
            .init(name: "Recursive",        value: "true"),
            .init(name: "Fields",           value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,CommunityRating,OfficialRating,Genres,ChildCount"),
            .init(name: "ImageTypeLimit",   value: "1"),
            .init(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop"),
            .init(name: "Limit",            value: "\(limit)"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }
}
