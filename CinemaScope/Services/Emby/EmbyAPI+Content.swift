import Foundation

// MARK: - Content
//
// Items, collections, playlists, continue watching, recently added,
// genres, favorites, and collection membership.

extension EmbyAPI {

    // MARK: - Items

    static func fetchItems(
        server: EmbyServer, userId: String, token: String,
        parentId: String, sortBy: String = "SortName",
        startIndex: Int = 0, limit: Int = 100
    ) async throws -> EmbyItemsResponse {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items")
        comps.queryItems = [
            .init(name: "ParentId",         value: parentId),
            .init(name: "IncludeItemTypes", value: "Movie,Series"),
            .init(name: "Recursive",        value: "true"),
            .init(name: "SortBy",           value: sortBy),
            .init(name: "SortOrder",        value: "Ascending"),
            .init(name: "Fields",           value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,BackdropImageTags"),
            .init(name: "ImageTypeLimit",   value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
            .init(name: "StartIndex",       value: "\(startIndex)"),
            .init(name: "Limit",            value: "\(limit)"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token))
    }

    // MARK: - Collections

    static func fetchCollections(server: EmbyServer, userId: String, token: String) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items")
        comps.queryItems = [
            .init(name: "IncludeItemTypes", value: "BoxSet"),
            .init(name: "Recursive",        value: "true"),
            .init(name: "SortBy",           value: "SortName"),
            .init(name: "SortOrder",        value: "Ascending"),
            .init(name: "Fields",           value: "PrimaryImageAspectRatio,Overview,ChildCount"),
            .init(name: "ImageTypeLimit",   value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }

    // MARK: - Playlists

    static func fetchPlaylists(server: EmbyServer, userId: String, token: String) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items")
        comps.queryItems = [
            .init(name: "IncludeItemTypes", value: "Playlist"),
            .init(name: "Recursive",        value: "true"),
            .init(name: "SortBy",           value: "SortName"),
            .init(name: "SortOrder",        value: "Ascending"),
            .init(name: "Fields",           value: "PrimaryImageAspectRatio,Overview,ChildCount"),
            .init(name: "ImageTypeLimit",   value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }

    // MARK: - Single Item (deep-link resolution)

    static func fetchItem(server: EmbyServer, userId: String, token: String, itemId: String) async throws -> EmbyItem {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items/\(itemId)")
        comps.queryItems = [
            .init(name: "Fields", value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,BackdropImageTags,People,Genres,OfficialRating,CommunityRating"),
            .init(name: "ImageTypeLimit",  value: "1"),
            .init(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItem.self, from: try await get(url: url, token: token))
    }

    // MARK: - Continue Watching / Recently Added

    static func fetchContinueWatching(server: EmbyServer, userId: String, token: String, limit: Int = 25) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items/Resume")
        comps.queryItems = [
            .init(name: "Limit",            value: "\(limit)"),
            .init(name: "Recursive",        value: "true"),
            .init(name: "IncludeItemTypes", value: "Movie,Episode"),
            .init(name: "Fields",           value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData"),
            .init(name: "ImageTypeLimit",   value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }

    static func fetchRecentlyAdded(server: EmbyServer, userId: String, token: String, parentId: String, limit: Int = 25) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items/Latest")
        comps.queryItems = [
            .init(name: "ParentId",       value: parentId),
            .init(name: "Limit",          value: "\(limit)"),
            .init(name: "Fields",         value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData"),
            .init(name: "ImageTypeLimit", value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode([EmbyItem].self, from: try await get(url: url, token: token))
    }

    // MARK: - Genres

    /// Fetch all genres that exist in the user's movie or TV library.
    static func fetchGenres(
        server: EmbyServer,
        userId: String,
        token: String,
        itemType: String = "Movie"   // "Movie" or "Series"
    ) async throws -> [String] {
        var comps = try urlComponents(server, path: "/Genres")
        comps.queryItems = [
            .init(name: "UserId",           value: userId),
            .init(name: "IncludeItemTypes", value: itemType),
            .init(name: "SortBy",           value: "SortName"),
            .init(name: "SortOrder",        value: "Ascending"),
            .init(name: "Recursive",        value: "true"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        let data = try await get(url: url, token: token)
        let response = try decode(EmbyGenreResponse.self, from: data)
        return response.items.map { $0.name }
    }

    /// Fetch items filtered by genre.
    static func fetchByGenre(
        server: EmbyServer,
        userId: String,
        token: String,
        genre: String,
        itemType: String = "Movie",
        limit: Int = 25
    ) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items")
        comps.queryItems = [
            .init(name: "Genres",           value: genre),
            .init(name: "IncludeItemTypes", value: itemType),
            .init(name: "Recursive",        value: "true"),
            .init(name: "SortBy",           value: "CommunityRating,SortName"),
            .init(name: "SortOrder",        value: "Descending"),
            .init(name: "Fields",           value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData"),
            .init(name: "ImageTypeLimit",   value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
            .init(name: "Limit",            value: "\(limit)"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }

    // MARK: - Collection Items (all, no limit, sorted by year)

    static func fetchCollectionItems(
        server: EmbyServer, userId: String, token: String, collectionId: String
    ) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items")
        comps.queryItems = [
            .init(name: "ParentId",          value: collectionId),
            .init(name: "SortBy",            value: "ProductionYear,SortName"),
            .init(name: "SortOrder",         value: "Ascending"),
            .init(name: "Fields",            value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,Genres,BackdropImageTags,CommunityRating,OfficialRating"),
            .init(name: "ImageTypeLimit",    value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
            .init(name: "Recursive",         value: "false"),
            .init(name: "Limit",             value: "500"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }

    // MARK: - Favorites

    /// Fetch all favorited movies and series for the user.
    static func fetchFavorites(
        server: EmbyServer, userId: String, token: String
    ) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items")
        comps.queryItems = [
            .init(name: "Filters",           value: "IsFavorite"),
            .init(name: "Recursive",         value: "true"),
            .init(name: "IncludeItemTypes",  value: "Movie,Series"),
            .init(name: "SortBy",            value: "SortName"),
            .init(name: "SortOrder",         value: "Ascending"),
            .init(name: "Fields",            value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,Genres,BackdropImageTags,CommunityRating,OfficialRating"),
            .init(name: "ImageTypeLimit",    value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }

    /// Mark or unmark an item as a favorite. Returns the updated UserData.
    @discardableResult
    static func toggleFavorite(
        server: EmbyServer, userId: String, token: String,
        itemId: String, isFavorite: Bool
    ) async throws -> UserData {
        let path = "/Users/\(userId)/FavoriteItems/\(itemId)"
        let url  = try endpoint(server, path: path)
        let data = isFavorite
            ? try await post(url: url, body: [:], token: token)
            : try await delete(url: url, token: token)
        return try decode(UserData.self, from: data)
    }

    // MARK: - Item Ancestors (used to find BoxSet / Collection membership)

    static func fetchAncestors(
        server: EmbyServer, userId: String, token: String, itemId: String
    ) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Items/\(itemId)/Ancestors")
        comps.queryItems = [
            .init(name: "UserId", value: userId),
            .init(name: "Fields", value: "PrimaryImageAspectRatio,Overview,ChildCount"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode([EmbyItem].self, from: try await get(url: url, token: token))
    }
}
