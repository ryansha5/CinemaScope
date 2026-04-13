import Foundation

// MARK: - EmbyAPI Errors

enum EmbyError: LocalizedError {
    case invalidURL
    case unauthorized
    case serverError(Int)
    case decodingError(String)
    case noMediaSource

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Invalid server URL."
        case .unauthorized:         return "Wrong username or password."
        case .serverError(let c):   return "Server error (\(c))."
        case .decodingError(let m): return "Response error: \(m)"
        case .noMediaSource:        return "No playable source found."
        }
    }
}

// MARK: - EmbyAPI

actor EmbyAPI {

    private static let clientInfo = "MediaBrowser Client=\"CinemaScope\", Device=\"AppleTV\", DeviceId=\"cinemascope-appletv-1\", Version=\"1.0\""

    // MARK: - Auth

    static func fetchUsers(server: EmbyServer) async throws -> [EmbyUser] {
        let url = try endpoint(server, path: "/Users/Public")
        let data = try await get(url: url)
        return try decode([EmbyUser].self, from: data)
    }

    static func authenticate(server: EmbyServer, username: String, password: String) async throws -> EmbyAuthResponse {
        let url = try endpoint(server, path: "/Users/AuthenticateByName")
        let data = try await post(url: url, body: ["Username": username, "Pw": password], token: nil)
        return try decode(EmbyAuthResponse.self, from: data)
    }

    // MARK: - Libraries

    static func fetchLibraries(server: EmbyServer, userId: String, token: String) async throws -> [EmbyLibrary] {
        let url = try endpoint(server, path: "/Users/\(userId)/Views")
        let data = try await get(url: url, token: token)
        return try decode(EmbyItemsResponse_Library.self, from: data).items
    }

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
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
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
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode([EmbyItem].self, from: try await get(url: url, token: token))
    }

    // MARK: - Search

    static func search(server: EmbyServer, userId: String, token: String, query: String, limit: Int = 50) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items")
        comps.queryItems = [
            .init(name: "SearchTerm",       value: query),
            .init(name: "IncludeItemTypes", value: "Movie,Series,BoxSet,Playlist"),
            .init(name: "Recursive",        value: "true"),
            .init(name: "Fields",           value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData"),
            .init(name: "ImageTypeLimit",   value: "1"),
            .init(name: "Limit",            value: "\(limit)"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }

    // MARK: - Detail / Playback

    static func fetchItemDetail(server: EmbyServer, userId: String, token: String, itemId: String) async throws -> EmbyItem {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items/\(itemId)")
        comps.queryItems = [.init(name: "Fields", value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,Genres,People,BackdropImageTags")]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItem.self, from: try await get(url: url, token: token))
    }

    static func playbackURL(server: EmbyServer, userId: String, token: String, itemId: String) async throws -> URL {
        var infoComps = try urlComponents(server, path: "/Items/\(itemId)/PlaybackInfo")
        infoComps.queryItems = [.init(name: "UserId", value: userId), .init(name: "StartTimeTicks", value: "0")]
        guard let infoURL = infoComps.url else { throw EmbyError.invalidURL }
        let info = try decode(EmbyPlaybackInfo.self, from: try await post(url: infoURL, body: [:], token: token))
        guard let source = info.mediaSources.first else { throw EmbyError.noMediaSource }

        let unsupportedAudio: Set<String> = ["truehd", "dts", "dtshd", "dts-hd"]
        let audioCodecs = source.mediaStreams?.filter { $0.type.lowercased() == "audio" }.compactMap { $0.codec?.lowercased() } ?? []
        let needsTranscode = !(source.supportsDirectStream ?? false) || audioCodecs.contains { unsupportedAudio.contains($0) }

        var comps = try urlComponents(server, path: "/Videos/\(itemId)/stream\(needsTranscode ? ".mp4" : "")")
        var params: [URLQueryItem] = [
            .init(name: "MediaSourceId", value: source.id),
            .init(name: "api_key",       value: token),
            .init(name: "DeviceId",      value: "cinemascope-appletv-1"),
        ]
        if needsTranscode {
            params += [
                .init(name: "VideoCodec",  value: "h264"),
                .init(name: "AudioCodec",  value: "aac"),
                .init(name: "AudioBitrate", value: "384000"),
                .init(name: "Static",      value: "false"),
            ]
        } else {
            params.append(.init(name: "Static", value: "true"))
        }
        comps.queryItems = params
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return url
    }

    // MARK: - Image URLs

    static func primaryImageURL(server: EmbyServer, itemId: String, tag: String?, width: Int = 300) -> URL? {
        guard tag != nil else { return nil }
        var comps = try? urlComponents(server, path: "/Items/\(itemId)/Images/Primary")
        comps?.queryItems = [.init(name: "width", value: "\(width)"), .init(name: "quality", value: "90")]
        return comps?.url
    }

    // MARK: - Networking

    static func get(url: URL, token: String? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return data
    }

    static func post(url: URL, body: [String: String], token: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return data
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299: return
        case 401: throw EmbyError.unauthorized
        default:
            print("[EmbyAPI] HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            throw EmbyError.serverError(http.statusCode)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw EmbyError.decodingError(error.localizedDescription) }
    }

    private static func authorizationHeader(token: String?) -> String {
        var h = clientInfo
        if let token { h += ", Token=\"\(token)\"" }
        return h
    }

    private static func endpoint(_ server: EmbyServer, path: String) throws -> URL {
        guard let base = server.baseURL, let url = URL(string: path, relativeTo: base) else { throw EmbyError.invalidURL }
        return url
    }

    static func urlComponents(_ server: EmbyServer, path: String) throws -> URLComponents {
        guard let comps = URLComponents(url: try endpoint(server, path: path), resolvingAgainstBaseURL: true) else { throw EmbyError.invalidURL }
        return comps
    }
}

private struct EmbyItemsResponse_Library: Codable {
    let items: [EmbyLibrary]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}
