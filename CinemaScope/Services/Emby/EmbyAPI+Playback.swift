import Foundation

// MARK: - Detail / Playback

extension EmbyAPI {

    static func fetchItemDetail(server: EmbyServer, userId: String, token: String, itemId: String) async throws -> EmbyItem {
        var comps = try urlComponents(server, path: "/Users/\(userId)/Items/\(itemId)")
        comps.queryItems = [.init(name: "Fields", value: "PrimaryImageAspectRatio,Overview,RunTimeTicks,UserData,Genres,People,BackdropImageTags,CommunityRating,OfficialRating,Taglines,Studios,ChildCount,EpisodeCount,SeasonUserData,SeriesStudio,ProviderIds")]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        return try decode(EmbyItem.self, from: try await get(url: url, token: token))
    }

    /// Fetch media technical specs without starting playback.
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
    ) async throws -> PlaybackResult {

        // ── Step 1: Fetch PlaybackInfo ──────────────────────────────
        var infoComps = try urlComponents(server, path: "/Items/\(itemId)/PlaybackInfo")
        infoComps.queryItems = [.init(name: "UserId", value: userId)]
        guard let infoURL = infoComps.url else { throw EmbyError.invalidURL }

        let info = try decode(EmbyPlaybackInfo.self,
                              from: try await postJSON(url: infoURL,
                                                       body: appleTVDeviceProfile(),
                                                       token: token))
        guard let source = info.mediaSources.first else { throw EmbyError.noMediaSource }

        // Capture the Emby-assigned session ID. Falls back to a local UUID only
        // if the server is very old and doesn't return one.
        var playSessionId = info.playSessionId ?? UUID().uuidString

        // ── Step 2: Gather facts from PlaybackInfo ──────────────────
        let allStreams          = source.mediaStreams ?? []

        // Log every audio stream's index and codec so we can see what Emby exposed
        let audioStreamsSummary = allStreams
            .filter { $0.type.lowercased() == "audio" }
            .map { s -> String in
                let idx     = s.index.map { "#\($0)" } ?? "#?"
                let codec   = s.codec ?? "?"
                let def     = s.isDefault == true ? " [default]" : ""
                let layout  = s.channelLayout.map { " \($0)" } ?? ""
                return "\(idx) \(codec)\(layout)\(def)"
            }
            .joined(separator: ", ")
        let subStreamsSummary = allStreams
            .filter { $0.type.lowercased() == "subtitle" }
            .map { s -> String in
                let idx   = s.index.map { "#\($0)" } ?? "#?"
                let codec = s.codec ?? "?"
                let def   = s.isDefault == true ? " [default]" : ""
                return "\(idx) \(codec)\(def)"
            }
            .joined(separator: ", ")

        // ── Step 2b: Difficult-file detection ───────────────────────
        //
        // Emby can fail to generate a valid master.m3u8 when:
        //   • The default audio track is TrueHD / MLP lossless — many server
        //     configurations can't transcode these directly.
        //   • PGS (bitmap) subtitles are selected for burn-in — this adds a
        //     second decode step that can stall or abort the transcode job.
        //
        // Strategy: detect the combination, then re-request PlaybackInfo with:
        //   • AudioStreamIndex = index of the first AC3/EAC3 fallback track
        //   • SubtitleStreamIndex = -1  (no subtitles)
        // Emby will generate a new PlaySessionId and a TranscodingUrl that
        // targets streams it can actually transcode.

        var activeSource    = source         // may be replaced by re-fetch below
        var activeSessionId = playSessionId

        let defaultAudio     = allStreams.first { $0.type.lowercased() == "audio" && $0.isDefault == true }
                             ?? allStreams.first { $0.type.lowercased() == "audio" }
        let defaultAudioCodec = (defaultAudio?.codec ?? "").lowercased()
        let hasTrueHD        = defaultAudioCodec.contains("truehd") || defaultAudioCodec.contains("mlp")
        let hasPGS           = allStreams.contains {
            let c = ($0.codec ?? "").lowercased()
            return $0.type.lowercased() == "subtitle" && (c.contains("pgs") || c.contains("pgssub") || c.contains("hdmv"))
        }
        let isDifficult      = hasTrueHD || hasPGS

        if isDifficult {
            // Find the best AC3/EAC3 fallback audio track (prefer default/first)
            let fallbackAudio = allStreams.first {
                $0.type.lowercased() == "audio" &&
                (($0.codec ?? "").lowercased() == "ac3" || ($0.codec ?? "").lowercased() == "eac3")
            }

            print("""
[Playback] ⚠️ Difficult file detected for '\(itemName)':
[Playback]   hasTrueHD:     \(hasTrueHD) (default audio: \(defaultAudioCodec.isEmpty ? "none" : defaultAudioCodec))
[Playback]   hasPGS:        \(hasPGS)
[Playback]   Audio streams: \(audioStreamsSummary.isEmpty ? "none" : audioStreamsSummary)
[Playback]   Sub streams:   \(subStreamsSummary.isEmpty ? "none" : subStreamsSummary)
[Playback]   AC3 fallback:  \(fallbackAudio.map { s in "index \(s.index.map { "\($0)" } ?? "?"), codec \(s.codec ?? "?")" } ?? "❌ none found")
[Playback]   → Re-requesting PlaybackInfo with AudioStreamIndex=\(fallbackAudio?.index.map{"\($0)"} ?? "default") SubtitleStreamIndex=-1
""")

            // Re-fetch PlaybackInfo with explicit safe stream selection
            var retryComps = try urlComponents(server, path: "/Items/\(itemId)/PlaybackInfo")
            var retryQuery: [URLQueryItem] = [.init(name: "UserId", value: userId)]
            if let audioIdx = fallbackAudio?.index {
                retryQuery.append(.init(name: "AudioStreamIndex", value: "\(audioIdx)"))
            }
            retryQuery.append(.init(name: "SubtitleStreamIndex", value: "-1"))
            retryComps.queryItems = retryQuery
            guard let retryURL = retryComps.url else { throw EmbyError.invalidURL }

            if let retryInfo = try? decode(EmbyPlaybackInfo.self,
                                           from: try await postJSON(url: retryURL,
                                                                     body: appleTVDeviceProfile(),
                                                                     token: token)),
               let retrySource = retryInfo.mediaSources.first {
                activeSource    = retrySource
                activeSessionId = retryInfo.playSessionId ?? UUID().uuidString
                print("[Playback] ✅ Re-fetch succeeded — new PlaySessionId: \(activeSessionId), TranscodingUrl: \(retrySource.transcodingUrl.map { String($0.prefix(80)) } ?? "nil")")
            } else {
                print("[Playback] ⚠️ Re-fetch failed — continuing with original PlaybackInfo")
            }
        }

        let container          = activeSource.container ?? "unknown"
        let videoCodec         = activeSource.videoStream?.codec ?? "unknown"
        let audioCodecs        = activeSource.audioStreams.compactMap { $0.codec }.joined(separator: ", ")
        let subCodecs          = activeSource.subtitleStreams.compactMap { $0.codec }.joined(separator: ", ")
        let supportsDP         = activeSource.supportsDirectPlay
        let supportsDS         = activeSource.supportsDirectStream
        let embyTranscodeUrl   = activeSource.transcodingUrl
        let embyDirectStreamUrl = activeSource.directStreamUrl
        let codecsSafe         = codecsAreSafeForAVPlayer(activeSource)
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
            case embyTranscode          = "Used Emby-provided TranscodingUrl exactly"
            case manualDirectPlay       = "⚠️ EMERGENCY: manual direct-play URL constructed — PlaybackInfo gave no usable URL"
            case manualTranscode        = "⚠️ EMERGENCY: manual transcode URL constructed — PlaybackInfo gave no usable URL"
            case unsafeCodecs           = "Client codec check: codecs not safe for AVPlayer — falling through to transcode"
            case noDirectPath           = "Emby did not provide a direct-play or direct-stream path"
            case dsSkipped              = "supportsDirectStream != true — skipped DirectStreamUrl, falling through to transcode"
        }

        var chosenPath   = "transcode"
        var playMethod   = "Transcode"          // Emby PlayMethod value for reporting
        var reason: Reason = .noDirectPath
        var finalURL: URL? = nil

        // Helper: resolve a raw Emby URL string (relative or absolute) → URL,
        // appending api_key if absent.  Logs a full param audit so 404 root
        // causes (missing MediaSourceId, no AudioStreamIndex, etc.) are visible.
        func resolveEmbyURL(_ raw: String, label: String) -> URL? {
            let wasRelative = !raw.hasPrefix("http")
            let absolute    = wasRelative ? server.url + raw : raw
            guard var comps = URLComponents(string: absolute) else {
                print("[Playback] ⚠️ Could not parse \(label) URL: \(raw.prefix(120))")
                return nil
            }
            var items = comps.queryItems ?? []

            // ── Param audit ────────────────────────────────────────────
            // Required for HLS transcode to start:
            func val(_ key: String) -> String? {
                items.first(where: { $0.name.lowercased() == key.lowercased() })?.value
            }
            func has(_ key: String) -> Bool { val(key) != nil }

            let hadApiKey        = has("api_key")
            let mediaSourceId    = val("MediaSourceId")
            let deviceId         = val("DeviceId")
            let playSessionId    = val("PlaySessionId")
            let videoCodecVal    = val("VideoCodec")
            let audioCodecVal    = val("AudioCodec")
            let audioStreamIdx   = val("AudioStreamIndex")
            let subStreamIdx     = val("SubtitleStreamIndex")
            let subMethod        = val("SubtitleMethod")
            let segContainer     = val("SegmentContainer")
            let staticVal        = val("Static")

            if !hadApiKey {
                items.append(.init(name: "api_key", value: token))
                comps.queryItems = items
            }
            guard let url = comps.url else { return nil }

            func present(_ v: String?, critical: Bool = false) -> String {
                if let v { return "✅ \(v)" }
                return critical ? "❌ MISSING" : "— not set"
            }

            print("""
[Playback] \(label)
[Playback]   path:                \(comps.path)
[Playback]   wasRelative:         \(wasRelative)
[Playback]   api_key:             \(hadApiKey ? "✅ present" : "➕ appended")
[Playback]   MediaSourceId:       \(present(mediaSourceId, critical: true))
[Playback]   DeviceId:            \(present(deviceId))
[Playback]   PlaySessionId:       \(present(playSessionId, critical: true))
[Playback]   VideoCodec:          \(present(videoCodecVal))
[Playback]   AudioCodec:          \(present(audioCodecVal))
[Playback]   AudioStreamIndex:    \(present(audioStreamIdx))
[Playback]   SubtitleStreamIndex: \(present(subStreamIdx))
[Playback]   SubtitleMethod:      \(present(subMethod))
[Playback]   SegmentContainer:    \(present(segContainer))
[Playback]   Static:              \(present(staticVal))
[Playback]   total length:        \(url.absoluteString.count) chars
""")
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
                .init(name: "MediaSourceId", value: activeSource.id),
                .init(name: "api_key",       value: token),
                .init(name: "DeviceId",      value: "CinemaScope-AppleTV"),
                .init(name: "Static",        value: "true"),
            ]
            if let url = comps.url {
                chosenPath = "direct-play"
                playMethod = "DirectPlay"
                reason     = .embySaysDPManualPath
                finalURL   = url
                print("[Playback] direct-play: source=manual-path (Emby authorised, no explicit DP URL in PlaybackInfo), length=\(url.absoluteString.count)")
            }
        }

        // ── Rule 2: Direct Stream — only when Emby explicitly says so ──
        // supportsDirectStream must be true. If it is nil or false the
        // DirectStreamUrl is unreliable (Emby returns it for structural
        // reasons but it 404s), so we skip it and fall through to transcode.
        if finalURL == nil && codecsSafe {
            if supportsDS == true, let dsUrl = embyDirectStreamUrl {
                if let url = resolveEmbyURL(dsUrl, label: "direct-stream (supportsDirectStream=true)") {
                    chosenPath = "direct-stream"
                    playMethod = "DirectStream"
                    reason     = .embySaysDS
                    finalURL   = url
                }
            } else if embyDirectStreamUrl != nil {
                // URL exists but flag is nil/false — log and skip to avoid 404
                let flagVal = supportsDS.map { "\($0)" } ?? "nil"
                print("[Playback] ⏭️ Skipping DirectStreamUrl: supportsDirectStream=\(flagVal) — falling through to transcode")
                reason = .dsSkipped
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
                    .init(name: "MediaSourceId", value: activeSource.id),
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
                    .init(name: "MediaSourceId",   value: activeSource.id),
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
[Playback] Audio streams:        \(audioStreamsSummary.isEmpty ? "none" : audioStreamsSummary)
[Playback] Sub streams:          \(subStreamsSummary.isEmpty ? "none" : subStreamsSummary)
[Playback] Difficult file:       \(isDifficult ? "⚠️ yes (hasTrueHD=\(hasTrueHD) hasPGS=\(hasPGS))" : "no")
[Playback] Stream re-fetch:      \(isDifficult ? (activeSource.id == source.id ? "attempted but used original" : "✅ used re-fetched source") : "n/a")
[Playback] supportsDirectPlay:   \(supportsDP.map { "\($0)" } ?? "nil")
[Playback] supportsDirectStream: \(supportsDS.map { "\($0)" } ?? "nil")
[Playback] Emby DirectStreamUrl: \(embyDirectStreamUrl.map { String($0.prefix(80)) } ?? "nil")
[Playback] Emby TranscodingUrl:  \(embyTranscodeUrl.map { String($0.prefix(80)) } ?? "nil")
[Playback] Codec check:          \(codecsSafe ? "✅ safe" : "⚠️ unsafe — codec(s) not in AVPlayer whitelist")
[Playback] ─────────────────────────────────────────
[Playback] Path chosen:          \(chosenPath)  (\(playMethod))
[Playback] PlaySessionId:        \(activeSessionId)
[Playback] MediaSourceId:        \(activeSource.id)
[Playback] Reason:               \(reason.rawValue)
[Playback] URL source:           \(isManual ? "⚠️ MANUALLY CONSTRUCTED" : "✅ from PlaybackInfo")
[Playback] Final URL length:     \(url.absoluteString.count) chars
[Playback] ══════════════════════════════════════════
""")

        // Suppress unused-variable warnings for vars captured only in logging
        _ = audioCodecs
        _ = subCodecs

        return PlaybackResult(
            url:           url,
            playSessionId: activeSessionId,
            mediaSourceId: activeSource.id,
            playMethod:    playMethod
        )
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Device Profile
    // ─────────────────────────────────────────────────────────────────

    private static func appleTVDeviceProfile() -> [String: Any] {
        // Transcoding protocol is HLS (not HTTP progressive).
        // HLS lets AVPlayer start on the first segment while the rest encode,
        // which is why direct-play works instantly but HTTP progressive
        // transcodes stall or fail on most files — the encode has to get far
        // enough ahead before AVPlayer receives any data.
        let json = """
        {
            "DeviceProfile": {
                "Name": "Pinea Apple TV 4K",
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
                        "Container": "ts",
                        "VideoCodec": "h264",
                        "AudioCodec": "aac,ac3",
                        "Protocol": "hls",
                        "Context": "Streaming",
                        "MaxAudioChannels": "6",
                        "BreakOnNonKeyFrames": true,
                        "MinSegments": 1
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

    static func forcedTranscodeURL(
        server: EmbyServer, userId: String, token: String, itemId: String
    ) async throws -> PlaybackResult {
        // Re-fetch PlaybackInfo to get a fresh HLS transcode session
        var infoComps = try urlComponents(server, path: "/Items/\(itemId)/PlaybackInfo")
        infoComps.queryItems = [.init(name: "UserId", value: userId)]
        guard let infoURL = infoComps.url else { throw EmbyError.invalidURL }

        let info = try decode(EmbyPlaybackInfo.self,
                              from: try await postJSON(url: infoURL,
                                                       body: appleTVDeviceProfile(),
                                                       token: token))
        guard let source = info.mediaSources.first else { throw EmbyError.noMediaSource }

        let playSessionId = info.playSessionId ?? UUID().uuidString

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
                    print("[Playback] 🆘 forcedTranscode: source=PlaybackInfo, playSessionId=\(playSessionId), wasRelative=\(wasRelative), length=\(url.absoluteString.count)")
                    return PlaybackResult(url: url, playSessionId: playSessionId, mediaSourceId: source.id, playMethod: "Transcode")
                }
            }
        }

        // Priority 2: EMERGENCY manual HLS fallback — only if Emby gave no TranscodingUrl.
        print("[Playback] 🚨 forcedTranscode EMERGENCY: no Emby TranscodingUrl — constructing manual HLS fallback")
        var comps = try urlComponents(server, path: "/Videos/\(itemId)/master.m3u8")
        comps.queryItems = [
            .init(name: "MediaSourceId",   value: source.id),
            .init(name: "api_key",         value: token),
            .init(name: "DeviceId",        value: "cinemascope-appletv"),
            .init(name: "PlaySessionId",   value: playSessionId),
            .init(name: "VideoCodec",      value: "h264"),
            .init(name: "AudioCodec",      value: "aac,ac3"),
            .init(name: "MaxVideoBitrate", value: "8000000"),
            .init(name: "AudioBitrate",    value: "192000"),
            .init(name: "AudioChannels",   value: "6"),
            .init(name: "MaxWidth",        value: "1920"),
            .init(name: "MaxHeight",       value: "1080"),
        ]
        guard let url = comps.url else { throw EmbyError.invalidURL }
        print("[Playback] 🚨 forcedTranscode manual HLS fallback: length=\(url.absoluteString.count)")
        return PlaybackResult(url: url, playSessionId: playSessionId, mediaSourceId: source.id, playMethod: "Transcode")
    }
}
