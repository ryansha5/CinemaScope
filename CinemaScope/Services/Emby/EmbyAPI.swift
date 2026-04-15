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
    // Multi-seed personalized recommendations.
    // Seeds come from recently-watched movies (by DatePlayed), not all-time play count.
    // Each result is paired with the seed that generated it for "Because you watched X" UI.
    // Christmas content is always excluded.

    static func fetchPersonalizedRecommendations(
        server: EmbyServer,
        userId: String,
        token: String,
        limit: Int = 20
    ) async throws -> [RecommendationItem] {

        // 1. Fetch the 8 most-recently-watched movies as seeds
        var recentComps = try urlComponents(server, path: "/Users/\(userId)/Items")
        recentComps.queryItems = [
            .init(name: "SortBy",           value: "DatePlayed"),
            .init(name: "SortOrder",        value: "Descending"),
            .init(name: "Filters",          value: "IsPlayed"),
            .init(name: "IncludeItemTypes", value: "Movie"),
            .init(name: "Recursive",        value: "true"),
            .init(name: "Limit",            value: "8"),
            .init(name: "Fields",           value: "Genres"),
            .init(name: "ImageTypeLimit",   value: "1"),
            .init(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop"),
        ]
        guard let recentURL = recentComps.url else { throw EmbyError.invalidURL }
        let recentlyWatched = try decode(EmbyItemsResponse.self,
                                         from: try await get(url: recentURL, token: token)).items

        guard !recentlyWatched.isEmpty else { return [] }

        // 2. For each seed, fetch similar movies and pair them
        var results:  [RecommendationItem] = []
        var seenIds = Set<String>()

        // Shuffle seeds so the row varies across sessions
        for seed in recentlyWatched.shuffled() {
            guard results.count < limit else { break }

            var simComps = try urlComponents(server, path: "/Items/\(seed.id)/Similar")
            simComps.queryItems = [
                .init(name: "UserId",           value: userId),
                .init(name: "Limit",            value: "6"),
                .init(name: "Fields",           value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,Genres,BackdropImageTags"),
                .init(name: "ImageTypeLimit",   value: "1"),
                .init(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop"),
            ]
            guard let simURL = simComps.url else { continue }

            let similars = (try? decode(EmbyItemsResponse.self,
                                        from: try await get(url: simURL, token: token)).items) ?? []

            // Take at most one recommendation per seed
            for movie in similars {
                guard results.count < limit else { break }
                guard !seenIds.contains(movie.id) else { continue }
                guard !movie.isChristmasContent    else { continue }
                seenIds.insert(movie.id)
                results.append(RecommendationItem(id: movie.id, recommendation: movie, becauseOf: seed))
                break   // one per seed — move on to the next watched movie
            }
        }

        // Final shuffle so seed groupings aren't visible to the user
        return results.shuffled()
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
        // Priority order — strict:
        //   1. Direct Play:    supportsDirectPlay=true → use Emby-provided direct-play path.
        //                      If Emby gives no explicit URL, fall back to manual direct-play.
        //   2. Direct Stream:  use source.directStreamUrl exactly as returned by PlaybackInfo.
        //   3. Transcode:      use source.transcodingUrl exactly as returned by PlaybackInfo.
        //   4. Manual fallback: EMERGENCY ONLY — only if PlaybackInfo gave no usable URL.
        //
        // URL handling rules for all Emby-provided URLs:
        //   - If relative, make absolute by prefixing server.url
        //   - Preserve full path and all query params exactly
        //   - Append api_key only if missing; otherwise leave URL untouched
        //   - Never trim, rewrite, simplify, or reconstruct an Emby-provided URL

        enum Reason: String {
            case embySaysDP             = "Emby supportsDirectPlay=true — used Emby-provided direct-play path"
            case embySaysDPManualPath   = "Emby supportsDirectPlay=true — no explicit URL, used manual direct-play fallback"
            case embySaysDS             = "Emby supportsDirectStream=true — used Emby DirectStreamUrl exactly"
            case embyDSUrlOnly          = "Emby DirectStreamUrl provided (supportsDirectStream nil/false) — trusted URL over flag"
            case embyTranscode          = "Used Emby-provided TranscodingUrl exactly"
            case manualDirectPlay       = "⚠️ EMERGENCY: manual direct-play URL constructed — PlaybackInfo gave no usable URL"
            case manualTranscode        = "⚠️ EMERGENCY: manual transcode URL constructed — PlaybackInfo gave no usable URL"
            case unsafeCodecs           = "Client codec check: codecs not safe for AVPlayer — falling through to transcode"
            case noDirectPath           = "Emby did not provide a direct-play or direct-stream path"
        }

        var chosenPath  = "transcode"
        var reason: Reason = .noDirectPath
        var finalURL: URL? = nil

        // Helper: resolve a raw Emby URL string (relative or absolute) → URL,
        // appending api_key if absent. Returns nil if the string is malformed.
        // Logs whether the original was relative and whether api_key was appended.
        func resolveEmbyURL(_ raw: String, label: String) -> URL? {
            let wasRelative = !raw.hasPrefix("http")
            let absolute    = wasRelative ? server.url + raw : raw
            guard var comps = URLComponents(string: absolute) else {
                print("[Playback] ⚠️ Could not parse \(label) URL: \(raw.prefix(120))")
                return nil
            }
            var items = comps.queryItems ?? []
            let hadApiKey = items.contains(where: { $0.name == "api_key" })
            if !hadApiKey {
                items.append(.init(name: "api_key", value: token))
                comps.queryItems = items
            }
            guard let url = comps.url else { return nil }
            print("[Playback] \(label): source=PlaybackInfo, wasRelative=\(wasRelative), apiKeyAppended=\(!hadApiKey), length=\(url.absoluteString.count)")
            return url
        }

        // ── Rule 1: Direct Play ──────────────────────────────────────
        // Emby says supportsDirectPlay AND container is native AND codecs are safe.
        // We do NOT construct the URL ourselves — we ask Emby for the direct path.
        // Emby's PlaybackInfo doesn't return an explicit "DirectPlayUrl" field, so
        // we use the well-known native stream path, but only when Emby authorises it.
        if supportsDP == true && nativeContainer && codecsSafe {
            // Build the standard native direct-play path exactly per spec
            var comps = try urlComponents(server, path: "/Videos/\(itemId)/stream")
            comps.queryItems = [
                .init(name: "MediaSourceId", value: source.id),
                .init(name: "api_key",       value: token),
                .init(name: "DeviceId",      value: "CinemaScope-AppleTV"),
                .init(name: "Static",        value: "true"),
            ]
            if let url = comps.url {
                chosenPath = "direct-play"
                reason     = .embySaysDPManualPath
                finalURL   = url
                print("[Playback] direct-play: source=manual-path (Emby authorised, no explicit DP URL in PlaybackInfo), length=\(url.absoluteString.count)")
            }
        }

        // ── Rule 2: Direct Stream — use Emby's URL exactly ──────────
        if finalURL == nil && codecsSafe {
            if let dsUrl = embyDirectStreamUrl {
                // supportsDirectStream may be true, nil, or even false —
                // if Emby gave us a DirectStreamUrl we trust the URL over the flag.
                let flagNote = supportsDS == true ? "supportsDirectStream=true" : "supportsDirectStream=\(supportsDS.map{"\($0)"} ?? "nil") (trusting URL)"
                if let url = resolveEmbyURL(dsUrl, label: "direct-stream (\(flagNote))") {
                    chosenPath = "direct-stream"
                    reason     = supportsDS == true ? .embySaysDS : .embyDSUrlOnly
                    finalURL   = url
                }
            }
        }

        // ── Rule 3: Transcode — use Emby's TranscodingUrl exactly ───
        if finalURL == nil {
            if !codecsSafe { reason = .unsafeCodecs }
            if let tcUrl = embyTranscodeUrl {
                if let url = resolveEmbyURL(tcUrl, label: "transcode") {
                    chosenPath = "transcode"
                    reason     = .embyTranscode
                    finalURL   = url
                }
            }
        }

        // ── Rule 4: Manual fallback — EMERGENCY / DEBUG ONLY ────────
        // Only reached if PlaybackInfo returned no usable URL at all.
        // Log loudly. These paths should never fire in normal operation.
        if finalURL == nil {
            print("[Playback] 🚨 EMERGENCY: PlaybackInfo gave no usable URL — constructing manual fallback")

            if nativeContainer && codecsSafe {
                // Manual direct-play fallback
                var comps = try urlComponents(server, path: "/Videos/\(itemId)/stream")
                comps.queryItems = [
                    .init(name: "MediaSourceId", value: source.id),
                    .init(name: "api_key",       value: token),
                    .init(name: "DeviceId",      value: "CinemaScope-AppleTV"),
                    .init(name: "Static",        value: "true"),
                ]
                if let url = comps.url {
                    chosenPath = "direct-play-manual"
                    reason     = .manualDirectPlay
                    finalURL   = url
                    print("[Playback] 🚨 manual-direct-play fallback: length=\(url.absoluteString.count)")
                }
            } else {
                // Manual transcode fallback
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
                    print("[Playback] 🚨 manual-transcode fallback: length=\(url.absoluteString.count)")
                }
            }
        }

        guard let url = finalURL else { throw EmbyError.invalidURL }

        // ── Step 4: Log full decision summary ───────────────────────
        let isManual = reason == .manualDirectPlay || reason == .manualTranscode || reason == .embySaysDPManualPath
        print("""
[Playback] ══════════════════════════════════════════
[Playback] Item:                 \(itemName.isEmpty ? itemId : itemName)
[Playback] Container:            \(container)
[Playback] Video codec:          \(videoCodec)
[Playback] Audio codecs:         \(audioCodecs.isEmpty ? "none" : audioCodecs)
[Playback] Subtitle codecs:      \(subCodecs.isEmpty ? "none" : subCodecs)
[Playback] supportsDirectPlay:   \(supportsDP.map { "\($0)" } ?? "nil")
[Playback] supportsDirectStream: \(supportsDS.map { "\($0)" } ?? "nil")
[Playback] Emby DirectStreamUrl: \(embyDirectStreamUrl.map { String($0.prefix(80)) } ?? "nil")
[Playback] Emby TranscodingUrl:  \(embyTranscodeUrl.map { String($0.prefix(80)) } ?? "nil")
[Playback] Codec check:          \(codecsSafe ? "✅ safe" : "⚠️ unsafe — codec(s) not in AVPlayer whitelist")
[Playback] ─────────────────────────────────────────
[Playback] Path chosen:          \(chosenPath)
[Playback] Reason:               \(reason.rawValue)
[Playback] URL source:           \(isManual ? "⚠️ MANUALLY CONSTRUCTED" : "✅ from PlaybackInfo")
[Playback] Final URL length:     \(url.absoluteString.count) chars
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

        // Priority 1: Use Emby's TranscodingUrl exactly — preserve all params,
        // only append api_key if missing. Never rewrite or reconstruct.
        if let tcUrl = source.transcodingUrl {
            let wasRelative = !tcUrl.hasPrefix("http")
            let absolute    = wasRelative ? server.url + tcUrl : tcUrl
            if var comps = URLComponents(string: absolute) {
                var items = comps.queryItems ?? []
                let hadApiKey = items.contains(where: { $0.name == "api_key" })
                if !hadApiKey { items.append(.init(name: "api_key", value: token)) }
                comps.queryItems = items
                if let url = comps.url {
                    print("[Playback] 🆘 forcedTranscode: source=PlaybackInfo, wasRelative=\(wasRelative), apiKeyAppended=\(!hadApiKey), length=\(url.absoluteString.count)")
                    return url
                }
            }
        }

        // Priority 2: EMERGENCY manual fallback — only if Emby gave no TranscodingUrl.
        // Params per spec: h264/aac+ac3, 8Mbps, 192k audio, 6ch, 1080p max.
        print("[Playback] 🚨 forcedTranscode EMERGENCY: no Emby TranscodingUrl — constructing manual fallback")
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
        guard let url = comps.url else { throw EmbyError.invalidURL }
        print("[Playback] 🚨 forcedTranscode manual fallback: length=\(url.absoluteString.count)")
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
