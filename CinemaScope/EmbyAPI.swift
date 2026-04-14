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

    /// Fetch all genres that exist in the user's movie or TV library
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

    /// Fetch items filtered by genre
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
        let data = try await get(url: url, token: token)
        return try decode(EmbyItemsResponse.self, from: data).items
    }

    // MARK: - Collection items (all, no limit, sorted by year)

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

    // MARK: - Series seasons

    static func fetchSeasons(
        server: EmbyServer, userId: String, token: String, seriesId: String
    ) async throws -> [EmbyItem] {
        var comps = try urlComponents(server, path: "/Shows/\(seriesId)/Seasons")
        comps.queryItems = [
            .init(name: "UserId",  value: userId),
            .init(name: "Fields", value: "PrimaryImageAspectRatio,UserData,ChildCount"),
            .init(name: "ImageTypeLimit", value: "1"),
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
            .init(name: "UserId",    value: userId),
            .init(name: "SeasonId",  value: seasonId),
            .init(name: "Fields",    value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,BackdropImageTags"),
            .init(name: "ImageTypeLimit", value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
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
            .init(name: "UserId", value: userId),
            .init(name: "Fields", value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData"),
            .init(name: "ImageTypeLimit", value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }

    // MARK: - Recommendations
    // Uses Emby's similar items endpoint seeded by the user's most-played content

    static func fetchRecommended(
        server: EmbyServer,
        userId: String,
        token: String,
        limit: Int = 25
    ) async throws -> [EmbyItem] {
        // 1. Get the user's most-played items
        var playedComps = try urlComponents(server, path: "/Users/\(userId)/Items")
        playedComps.queryItems = [
            .init(name: "SortBy",           value: "PlayCount"),
            .init(name: "SortOrder",        value: "Descending"),
            .init(name: "Filters",          value: "IsPlayed"),
            .init(name: "IncludeItemTypes", value: "Movie,Series"),
            .init(name: "Recursive",        value: "true"),
            .init(name: "Limit",            value: "5"),
            .init(name: "Fields",           value: "Genres"),
            .init(name: "ImageTypeLimit",   value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
        ]
        guard let playedURL = playedComps.url else { throw EmbyError.invalidURL }
        let played = try decode(EmbyItemsResponse.self,
                                from: try await get(url: playedURL, token: token)).items

        guard let seed = played.first else { return [] }

        // 2. Fetch similar items to the most-played
        var simComps = try urlComponents(server, path: "/Items/\(seed.id)/Similar")
        simComps.queryItems = [
            .init(name: "UserId",           value: userId),
            .init(name: "Limit",            value: "\(limit)"),
            .init(name: "Fields",           value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData"),
            .init(name: "ImageTypeLimit",   value: "1"),
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
        ]
        guard let simURL = simComps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self,
                          from: try await get(url: simURL, token: token)).items
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
            .init(name: "EnableImageTypes",  value: "Primary,Thumb,Backdrop"),
            .init(name: "Limit",            value: "\(limit)"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItemsResponse.self, from: try await get(url: url, token: token)).items
    }

    // MARK: - Detail / Playback

    static func fetchItemDetail(server: EmbyServer, userId: String, token: String, itemId: String) async throws -> EmbyItem {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items/\(itemId)")
        comps.queryItems = [.init(name: "Fields", value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,Genres,People,BackdropImageTags,CommunityRating,OfficialRating,Taglines,Studios,ChildCount,EpisodeCount,SeasonUserData,SeriesStudio,ProviderIds")]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItem.self, from: try await get(url: url, token: token))
    }

    // Fetch media technical specs without starting playback
    static func fetchMediaInfo(
        server: EmbyServer, userId: String, token: String, itemId: String
    ) async throws -> EmbyMediaSource? {
        var comps = try urlComponents(server, path: "/Items/\(itemId)/PlaybackInfo")
        comps.queryItems = [.init(name: "UserId", value: userId)]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        let info = try decode(EmbyPlaybackInfo.self, from: try await post(url: url, body: [:], token: token))
        return info.mediaSources.first
    }

    private static let appleTVVideoCodecs: Set<String> = [
        "h264", "avc", "hevc", "h265", "vp9", "av1", "mpeg4", "mpeg2video"
    ]

    private static let appleTVAudioCodecs: Set<String> = [
        "aac", "mp3", "ac3", "eac3", "alac", "flac", "opus", "pcm_s16le", "pcm_s24le"
    ]

    static func playbackURL(
        server: EmbyServer, userId: String, token: String, itemId: String
    ) async throws -> URL {
        // Ask Emby for playback info — send Apple TV device profile so
        // Emby can make the right direct-play/transcode decision itself
        var infoComps = try urlComponents(server, path: "/Items/\(itemId)/PlaybackInfo")
        infoComps.queryItems = [.init(name: "UserId", value: userId)]
        guard let infoURL = infoComps.url else { throw EmbyError.invalidURL }

        let deviceProfile = appleTVDeviceProfile()
        let info = try decode(EmbyPlaybackInfo.self,
                              from: try await postJSON(url: infoURL, body: deviceProfile, token: token))
        guard let source = info.mediaSources.first else { throw EmbyError.noMediaSource }

        // Always direct stream — server has transcoding disabled.
        // Emby remuxes MKV/AVI/etc to HTTP byte stream at zero CPU cost with Static=true.
        // The container doesn't matter — only the codec matters for Apple TV compatibility.
        let container = (source.container ?? "unknown").lowercased()
        print("[EmbyAPI] ✅ Direct Stream — \(container) container")

        var comps = try urlComponents(server, path: "/Videos/\(itemId)/stream")
        let params: [URLQueryItem] = [
            .init(name: "MediaSourceId", value: source.id),
            .init(name: "api_key",       value: token),
            .init(name: "DeviceId",      value: "CinemaScope-AppleTV"),
            .init(name: "Static",        value: "true"),
        ]
        comps.queryItems = params
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return url
    }


    private static func appleTVDeviceProfile() -> [String: Any] {
        // Use a JSON string to avoid Swift type inference issues with mixed [String: Any] dicts
        let json = """
        {
            "DeviceProfile": {
                "Name": "Apple TV 4K - CinemaScope",
                "MaxStreamingBitrate": 120000000,
                "MaxStaticBitrate": 120000000,
                "DirectPlayProfiles": [
                    {
                        "Type": "Video",
                        "Container": "mp4,m4v,mov,mkv,m2ts,ts,avi,webm",
                        "VideoCodec": "h264,hevc,h265,mpeg4,vp9,av1",
                        "AudioCodec": "aac,mp3,ac3,eac3,alac,flac,opus,pcm_s16le,pcm_s24le"
                    }
                ],
                "TranscodingProfiles": [
                    {
                        "Type": "Video",
                        "Container": "mp4",
                        "VideoCodec": "h264,hevc",
                        "AudioCodec": "aac,ac3",
                        "Protocol": "http",
                        "Context": "Streaming",
                        "MaxAudioChannels": "6",
                        "TranscodeSeekInfo": "Auto",
                        "EstimateContentLength": false
                    }
                ],
                "ContainerProfiles": [],
                "CodecProfiles": [
                    {
                        "Type": "Video",
                        "Codec": "h264",
                        "Conditions": [
                            {
                                "Condition": "LessThanEqual",
                                "Property": "VideoLevel",
                                "Value": "52",
                                "IsRequired": false
                            }
                        ]
                    },
                    {
                        "Type": "Video",
                        "Codec": "hevc,h265",
                        "Conditions": [
                            {
                                "Condition": "LessThanEqual",
                                "Property": "VideoLevel",
                                "Value": "60",
                                "IsRequired": false
                            }
                        ]
                    }
                ],
                "SubtitleProfiles": [
                    { "Format": "vtt", "Method": "External" },
                    { "Format": "srt", "Method": "External" },
                    { "Format": "ass", "Method": "External" }
                ],
                "ResponseProfiles": [
                    { "Type": "Video", "Container": "m4v", "MimeType": "video/mp4" }
                ]
            }
        }
        """
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    // MARK: - Image URLs

    static func primaryImageURL(server: EmbyServer, itemId: String, tag: String?, width: Int = 300) -> URL? {
        guard tag != nil else { return nil }
        var comps = try? urlComponents(server, path: "/Items/\(itemId)/Images/Primary")
        comps?.queryItems = [.init(name: "width", value: "\(width)"), .init(name: "quality", value: "90")]
        return comps?.url
    }

    static func thumbImageURL(server: EmbyServer, itemId: String, tag: String?, width: Int = 500) -> URL? {
        guard tag != nil else { return nil }
        var comps = try? urlComponents(server, path: "/Items/\(itemId)/Images/Thumb")
        comps?.queryItems = [.init(name: "width", value: "\(width)"), .init(name: "quality", value: "90")]
        return comps?.url
    }

    static func backdropImageURL(server: EmbyServer, itemId: String, tag: String?, width: Int = 1280) -> URL? {
        guard let tag else { return nil }
        return URL(string: "\(server.url)/Items/\(itemId)/Images/Backdrop?tag=\(tag)&width=\(width)&quality=90")
    }

    // MARK: - Playback Reporting
    // Emby tracks watch progress via these three calls:
    //   playbackStart  — called when playback begins
    //   playbackProgress — called periodically (every ~10s) while playing
    //   playbackStop   — called when user exits, with final position

    static func reportPlaybackStart(
        server: EmbyServer, userId: String, token: String,
        itemId: String, sessionId: String
    ) async {
        guard var comps = try? urlComponents(server, path: "/Sessions/Playing") else { return }
        comps.queryItems = [
            .init(name: "ItemId",     value: itemId),
            .init(name: "SessionId",  value: sessionId),
            .init(name: "UserId",     value: userId),
            .init(name: "PlayMethod", value: "DirectStream"),
        ]
        guard let url = comps.url else { return }
        _ = try? await post(url: url, body: [:], token: token)
    }

    static func reportPlaybackProgress(
        server: EmbyServer, token: String,
        itemId: String, sessionId: String,
        positionTicks: Int64, isPaused: Bool
    ) async {
        guard var comps = try? urlComponents(server, path: "/Sessions/Playing/Progress") else { return }
        comps.queryItems = [
            .init(name: "ItemId",        value: itemId),
            .init(name: "SessionId",     value: sessionId),
            .init(name: "PositionTicks", value: "\(positionTicks)"),
            .init(name: "IsPaused",      value: isPaused ? "true" : "false"),
            .init(name: "PlayMethod",    value: "DirectStream"),
        ]
        guard let url = comps.url else { return }
        _ = try? await post(url: url, body: [:], token: token)
    }

    static func reportPlaybackStop(
        server: EmbyServer, token: String,
        itemId: String, sessionId: String,
        positionTicks: Int64
    ) async {
        guard var comps = try? urlComponents(server, path: "/Sessions/Playing/Stopped") else { return }
        comps.queryItems = [
            .init(name: "ItemId",        value: itemId),
            .init(name: "SessionId",     value: sessionId),
            .init(name: "PositionTicks", value: "\(positionTicks)"),
            .init(name: "PlayMethod",    value: "DirectStream"),
        ]
        guard let url = comps.url else { return }
        _ = try? await post(url: url, body: [:], token: token)
    }

    // MARK: - Networking

    static func get(url: URL, token: String? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return data
    }

    static func postJSON(url: URL, body: [String: Any], token: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
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
