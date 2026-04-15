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

    // ─────────────────────────────────────────────────────────────────
    // MARK: - AVPlayer Codec Tables (advisory only)
    // Used to assess client-side safety. NOT used to override Emby's decision.
    // ─────────────────────────────────────────────────────────────────

    private static let avpVideoCodecs: Set<String> = [
        "h264", "avc", "avc1",
        "hevc", "h265", "hvc1", "hev1",
        "mpeg4", "mp4v",
    ]

    private static let avpDirectPlayContainers: Set<String> = [
        "mp4", "m4v", "mov"
    ]

    private static let avpAudioCodecs: Set<String> = [
        "aac", "mp3", "mp2", "ac3", "eac3",
        "alac", "flac",
        "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be",
        "opus",
    ]

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Client-side codec safety assessment (advisory)
    // Returns true only if all codecs are known safe for AVPlayer.
    // This is used to CONFIRM a path Emby already offers — not to choose one.
    // ─────────────────────────────────────────────────────────────────

    private static func codecsAreSafeForAVPlayer(_ source: EmbyMediaSource) -> Bool {
        let videoCodec  = (source.videoStream?.codec ?? "").lowercased()
        let audioCodecs = source.audioStreams.map { ($0.codec ?? "").lowercased() }

        // Video must be known-safe (empty = unknown = treat as unsafe)
        guard !videoCodec.isEmpty, avpVideoCodecs.contains(videoCodec) else { return false }

        // At least one audio track must be safe
        let hasSafeAudio = audioCodecs.isEmpty || audioCodecs.contains { avpAudioCodecs.contains($0) }
        return hasSafeAudio
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - playbackURL
    // Emby PlaybackInfo is the primary source of truth.
    // Client codec analysis is advisory — used only to confirm, not override.
    // ─────────────────────────────────────────────────────────────────

    static func playbackURL(
        server: EmbyServer, userId: String, token: String,
        itemId: String, itemName: String = ""
    ) async throws -> URL {

        // ── Step 1: Fetch PlaybackInfo ──────────────────────────────
        var infoComps = try urlComponents(server, path: "/Items/\(itemId)/PlaybackInfo")
        infoComps.queryItems = [.init(name: "UserId", value: userId)]
        guard let infoURL = infoComps.url else { throw EmbyError.invalidURL }

        let info = try decode(EmbyPlaybackInfo.self,
                              from: try await postJSON(url: infoURL,
                                                       body: appleTVDeviceProfile(),
                                                       token: token))
        guard let source = info.mediaSources.first else { throw EmbyError.noMediaSource }

        // ── Step 2: Gather facts from PlaybackInfo ──────────────────
        let container          = source.container ?? "unknown"
        let videoCodec         = source.videoStream?.codec ?? "unknown"
        let audioCodecs        = source.audioStreams.compactMap { $0.codec }.joined(separator: ", ")
        let subCodecs          = source.subtitleStreams.compactMap { $0.codec }.joined(separator: ", ")
        let supportsDP         = source.supportsDirectPlay
        let supportsDS         = source.supportsDirectStream
        let embyTranscodeUrl   = source.transcodingUrl
        let embyDirectStreamUrl = source.directStreamUrl
        let codecsSafe         = codecsAreSafeForAVPlayer(source)
        let nativeContainer    = avpDirectPlayContainers.contains(container.lowercased())

        // ── Step 3: Decision logic (Emby is authoritative) ─────────
        //
        // Rule 1: Direct Play — Emby says it's safe AND container is native AND codecs are safe
        // Rule 2: Direct Stream — Emby provides a valid direct stream URL AND codecs are safe
        // Rule 3: Transcode — use Emby's transcodingUrl (preferred) or fall back to manual
        // Rule 4: If no valid URL can be constructed, throw

        enum Reason: String {
            case embySaysDP         = "Emby supportsDirectPlay=true, native container, safe codecs"
            case embySaysDS         = "Emby supportsDirectStream=true, safe codecs, DirectStreamUrl provided"
            case embyDSUrlOnly      = "Emby DirectStreamUrl provided, safe codecs (supportsDirectStream nil/false)"
            case embyTranscode      = "Emby-provided TranscodingUrl used"
            case manualTranscode    = "Manual transcode URL constructed (no Emby URL available)"
            case unsafeCodecs       = "Client codec check: codecs not safe for AVPlayer"
            case noDirectPath       = "Emby did not provide a direct play or stream path"
        }

        var chosenPath = "transcode"
        var reason: Reason = .noDirectPath
        var finalURL: URL? = nil

        // Rule 1: Direct Play
        if supportsDP == true && nativeContainer && codecsSafe {
            var comps = try urlComponents(server, path: "/Videos/\(itemId)/stream")
            comps.queryItems = [
                .init(name: "MediaSourceId", value: source.id),
                .init(name: "api_key",       value: token),
                .init(name: "DeviceId",      value: "CinemaScope-AppleTV"),
                .init(name: "Static",        value: "true"),
            ]
            if let url = comps.url {
                chosenPath = "direct-play"
                reason     = .embySaysDP
                finalURL   = url
            }
        }

        // Rule 2: Direct Stream — Emby says OK and provides a URL
        if finalURL == nil && codecsSafe {
            if supportsDS == true, let dsUrl = embyDirectStreamUrl {
                // Use Emby's DirectStreamUrl, ensuring api_key is present
                let base = dsUrl.hasPrefix("http") ? dsUrl : server.url + dsUrl
                if var comps = URLComponents(string: base) {
                    var items = comps.queryItems ?? []
                    if !items.contains(where: { $0.name == "api_key" }) {
                        items.append(.init(name: "api_key", value: token))
                    }
                    comps.queryItems = items
                    if let url = comps.url {
                        chosenPath = "direct-stream"
                        reason     = .embySaysDS
                        finalURL   = url
                    }
                }
            } else if let dsUrl = embyDirectStreamUrl {
                // Emby provided a DirectStreamUrl even though supportsDirectStream
                // is nil/false — trust the URL over the flag, but note it
                let base = dsUrl.hasPrefix("http") ? dsUrl : server.url + dsUrl
                if var comps = URLComponents(string: base) {
                    var items = comps.queryItems ?? []
                    if !items.contains(where: { $0.name == "api_key" }) {
                        items.append(.init(name: "api_key", value: token))
                    }
                    comps.queryItems = items
                    if let url = comps.url {
                        chosenPath = "direct-stream"
                        reason     = .embyDSUrlOnly
                        finalURL   = url
                    }
                }
            }
        }

        // Rule 3: Transcode — use Emby's URL first, manual fallback only if none
        if finalURL == nil {
            if !codecsSafe { reason = .unsafeCodecs }
            if let tcUrl = embyTranscodeUrl {
                let base = tcUrl.hasPrefix("http") ? tcUrl : server.url + tcUrl
                if var comps = URLComponents(string: base) {
                    var items = comps.queryItems ?? []
                    if !items.contains(where: { $0.name == "api_key" }) {
                        items.append(.init(name: "api_key", value: token))
                    }
                    comps.queryItems = items
                    if let url = comps.url {
                        chosenPath = "transcode"
                        reason     = .embyTranscode
                        finalURL   = url
                    }
                }
            }
        }

        // Rule 4: Manual transcode — last resort, log clearly that we constructed it
        if finalURL == nil {
            var comps = try urlComponents(server, path: "/Videos/\(itemId)/stream.mp4")
            comps.queryItems = [
                .init(name: "MediaSourceId",   value: source.id),
                .init(name: "api_key",         value: token),
                .init(name: "DeviceId",        value: "CinemaScope-AppleTV"),
                .init(name: "VideoCodec",      value: "h264"),
                .init(name: "AudioCodec",      value: "aac,ac3"),
                .init(name: "MaxVideoBitrate", value: "8000000"),
                .init(name: "AudioBitrate",    value: "192000"),
                .init(name: "AudioChannels",   value: "6"),
                .init(name: "MaxWidth",        value: "1920"),
                .init(name: "MaxHeight",       value: "1080"),
                .init(name: "Static",          value: "false"),
            ]
            if let url = comps.url {
                chosenPath = "transcode-manual"
                reason     = .manualTranscode
                finalURL   = url
            }
        }

        guard let url = finalURL else { throw EmbyError.invalidURL }

        // ── Step 4: Log everything ──────────────────────────────────
        print("""
[Playback] ══════════════════════════════════════════
[Playback] Item:               \(itemName.isEmpty ? itemId : itemName)
[Playback] Container:          \(container)
[Playback] Video codec:        \(videoCodec)
[Playback] Audio codecs:       \(audioCodecs.isEmpty ? "none" : audioCodecs)
[Playback] Subtitle codecs:    \(subCodecs.isEmpty ? "none" : subCodecs)
[Playback] supportsDirectPlay: \(supportsDP.map { "\($0)" } ?? "nil")
[Playback] supportsDirectStream: \(supportsDS.map { "\($0)" } ?? "nil")
[Playback] Emby DirectStreamUrl: \(embyDirectStreamUrl ?? "nil")
[Playback] Emby TranscodingUrl:  \(embyTranscodeUrl?.prefix(80) ?? "nil")
[Playback] Codec check:        \(codecsSafe ? "✅ safe" : "⚠️ unsafe")
[Playback] ─────────────────────────────────────────
[Playback] Path chosen:        \(chosenPath)
[Playback] Reason:             \(reason.rawValue)
[Playback] URL type:           \(chosenPath.contains("manual") ? "⚠️ MANUALLY CONSTRUCTED" : "✅ from PlaybackInfo")
[Playback] ══════════════════════════════════════════
""")

        return url
    }


    // ─────────────────────────────────────────────────────────────────
    // MARK: - Device Profile

    private static func appleTVDeviceProfile() -> [String: Any] {
        let json = """
        {
            "DeviceProfile": {
                "Name": "CinemaScope Apple TV 4K",
                "MaxStreamingBitrate": 120000000,
                "DirectPlayProfiles": [
                    {
                        "Type": "Video",
                        "Container": "mp4,m4v,mov",
                        "VideoCodec": "h264,hevc,h265",
                        "AudioCodec": "aac,mp3,ac3,eac3,alac,flac,opus"
                    }
                ],
                "TranscodingProfiles": [
                    {
                        "Type": "Video",
                        "Container": "mp4",
                        "VideoCodec": "h264",
                        "AudioCodec": "aac,ac3",
                        "Protocol": "http",
                        "Context": "Streaming",
                        "MaxAudioChannels": "6"
                    }
                ],
                "ContainerProfiles": [],
                "CodecProfiles": [],
                "SubtitleProfiles": [
                    { "Format": "vtt", "Method": "External" },
                    { "Format": "srt", "Method": "External" }
                ]
            }
        }
        """
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    // MARK: - Forced Transcode URL
    // Called by PlaybackEngine retry handler when primary path fails.
    // Always asks Emby to transcode to a safe H.264/AAC MP4.
    // ─────────────────────────────────────────────────────────────────

    static func forcedTranscodeURL(
        server: EmbyServer, userId: String, token: String, itemId: String
    ) async throws -> URL {
        // Re-fetch PlaybackInfo to get a fresh transcode session
        var infoComps = try urlComponents(server, path: "/Items/\(itemId)/PlaybackInfo")
        infoComps.queryItems = [.init(name: "UserId", value: userId)]
        guard let infoURL = infoComps.url else { throw EmbyError.invalidURL }

        let info = try decode(EmbyPlaybackInfo.self,
                              from: try await postJSON(url: infoURL,
                                                       body: appleTVDeviceProfile(),
                                                       token: token))
        guard let source = info.mediaSources.first else { throw EmbyError.noMediaSource }

        // Prefer Emby's own transcode URL — it accounts for subtitle burning etc.
        if let tcUrl = source.transcodingUrl {
            let fullUrl = tcUrl.hasPrefix("http") ? tcUrl : server.url + tcUrl
            if var comps = URLComponents(string: fullUrl) {
                var items = comps.queryItems ?? []
                if !items.contains(where: { $0.name == "api_key" }) {
                    items.append(.init(name: "api_key", value: token))
                }
                comps.queryItems = items
                if let url = comps.url {
                    print("[Playback] 🆘 Forced transcode URL from Emby: \(url.absoluteString.prefix(80))")
                    return url
                }
            }
        }

        // Manual fallback — conservative settings for maximum compatibility
        var comps = try urlComponents(server, path: "/Videos/\(itemId)/stream.mp4")
        comps.queryItems = [
            .init(name: "MediaSourceId",   value: source.id),
            .init(name: "api_key",         value: token),
            .init(name: "DeviceId",        value: "CinemaScope-AppleTV"),
            .init(name: "VideoCodec",      value: "h264"),
            .init(name: "AudioCodec",      value: "aac"),
            .init(name: "MaxVideoBitrate", value: "10000000"),
            .init(name: "VideoBitrate",    value: "6000000"),
            .init(name: "AudioBitrate",    value: "192000"),
            .init(name: "AudioChannels",   value: "2"),
            .init(name: "MaxWidth",        value: "1920"),
            .init(name: "MaxHeight",       value: "1080"),
            .init(name: "Static",          value: "false"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        print("[Playback] 🆘 Forced transcode URL (manual): \(url.absoluteString.prefix(80))")
        return url
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
