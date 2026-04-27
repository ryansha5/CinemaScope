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
        let allStreams   = source.mediaStreams ?? []
        let audioStreams = allStreams.filter { $0.type.lowercased() == "audio" }

        // Compact audio summary for the final decision log
        let audioStreamsSummary = audioStreams.enumerated().map { (pos, s) -> String in
            let embyIdx = s.index.map { "#\($0)" } ?? "#?"
            let codec   = s.codec ?? "?"
            let def     = s.isDefault == true ? " [default]" : ""
            let layout  = s.channelLayout.map { " \($0)" } ?? ""
            return "\(embyIdx) \(codec)\(layout)\(def)"
        }.joined(separator: ", ")
        let subStreamsSummary = allStreams
            .filter { $0.type.lowercased() == "subtitle" }
            .map { s -> String in
                let idx   = s.index.map { "#\($0)" } ?? "#?"
                let codec = s.codec ?? "?"
                return "\(idx) \(codec)"
            }
            .joined(separator: ", ")

        // ── Step 2b: Difficult-file detection ───────────────────────
        //
        // Emby fails to produce a working master.m3u8 when:
        //   • Default audio is TrueHD/MLP — most servers can't transcode this live.
        //   • PGS bitmap subtitles need burn-in — stalls or aborts the transcode.
        //
        // Fix: re-request PlaybackInfo with a conservative H.264-only device profile
        // and the best AC3/EAC3 fallback track (highest channel count wins).
        // AudioStreamIndex is embedded in BOTH the POST body and query params for
        // maximum compatibility across Emby versions.

        var activeSource             = source
        var activeSessionId          = playSessionId
        var refetchSucceeded         = false
        var selectedFallbackAudioIndex: Int? = nil  // carried into PlaybackResult + retry
        /// Set during difficult-file re-fetch if Emby returns the wrong AudioStreamIndex —
        /// overrides activeSource.transcodingUrl in Rule 3 so the patched URL is used.
        var overrideTranscodingUrl: String? = nil

        let defaultAudio      = audioStreams.first { $0.isDefault == true } ?? audioStreams.first
        let defaultAudioCodec = (defaultAudio?.codec ?? "").lowercased()
        let hasTrueHD         = defaultAudioCodec.contains("truehd") || defaultAudioCodec.contains("mlp")
        let hasPGS            = allStreams.contains {
            let c = ($0.codec ?? "").lowercased()
            return $0.type.lowercased() == "subtitle"
                && (c.contains("pgs") || c.contains("pgssub") || c.contains("hdmv"))
        }
        let isDifficult = hasTrueHD || hasPGS

        if isDifficult {
            // Verbose per-stream log: all metadata fields that help diagnose
            // language-preference overrides from Emby server.
            let audioDetailLines = audioStreams.enumerated().map { (pos, s) -> String in
                let embyIdx    = s.index.map { "\($0)" } ?? "?"
                let codec      = s.codec ?? "?"
                let ch         = s.channels.map { "\($0)ch" } ?? "?ch"
                let layout     = s.channelLayout.map { " \($0)" } ?? ""
                let lang       = s.language.map      { " lang=\($0)" }       ?? " lang=?"
                let dispTitle  = s.displayTitle.map  { " | \"\($0)\""  }     ?? ""
                let titleExtra = (s.title != nil && s.title != s.displayTitle)
                                  ? s.title.map { " (title: \"\($0)\")" } ?? ""
                                  : ""
                let def        = s.isDefault == true  ? " [default]" : ""
                let forced     = s.isForced  == true  ? " [forced]"  : ""
                return "[Playback]     display #\(pos+1) | embyIndex=\(embyIdx) | codec=\(codec) | \(ch)\(layout)\(lang)\(dispTitle)\(titleExtra)\(def)\(forced)"
            }.joined(separator: "\n")

            // Best fallback: AC3/EAC3 with the most channels (5.1 before stereo).
            //
            // FUTURE preference policy (not yet implemented):
            //   .preferOriginalLanguage — pick highest-channel AC3/EAC3 regardless of lang
            //   .preferEnglish          — bias toward lang="eng" among compatible streams
            //   .preferHighestChannel   — current behaviour (codec-first, then channels)
            //
            // We always use .preferHighestChannel on difficult files because the goal here
            // is transcoder compatibility, not user language preference. Emby may override
            // to the user's preferred language anyway — if it does, the mismatch log below
            // will identify it and the URL patch will restore our selection.
            let fallbackAudio = audioStreams
                .filter { let c = ($0.codec ?? "").lowercased(); return c == "ac3" || c == "eac3" }
                .sorted { ($0.channels ?? 0) > ($1.channels ?? 0) }
                .first

            selectedFallbackAudioIndex = fallbackAudio?.index

            let fallbackDesc: String
            if let fa = fallbackAudio {
                let embyIdx   = fa.index.map { "\($0)" } ?? "?"
                let ch        = fa.channels.map { "\($0)ch" } ?? "?ch"
                let layout    = fa.channelLayout.map { " \($0)" } ?? ""
                let lang      = fa.language.map { " lang=\($0)" } ?? ""
                let disp      = fa.displayTitle.map { " \"\($0)\"" } ?? ""
                fallbackDesc  = "embyIndex=\(embyIdx) | \(fa.codec ?? "?")\(layout.isEmpty && ch == "?ch" ? "" : " | \(ch)\(layout)")\(lang)\(disp)"
            } else {
                fallbackDesc = "❌ none found — will use default (may fail)"
            }

            print("""
[Playback] ⚠️ Difficult file detected for '\(itemName)':
[Playback]   hasTrueHD: \(hasTrueHD)  (default codec: \(defaultAudioCodec.isEmpty ? "none" : defaultAudioCodec))
[Playback]   hasPGS:    \(hasPGS)
[Playback]   Audio streams:
\(audioDetailLines.isEmpty ? "[Playback]     none" : audioDetailLines)
[Playback]   Sub streams: \(subStreamsSummary.isEmpty ? "none" : subStreamsSummary)
[Playback]   Selected fallback: \(fallbackDesc)
[Playback]   → Re-fetching PlaybackInfo (H.264-only profile, AudioStreamIndex=\(fallbackAudio?.index.map{"\($0)"} ?? "?"), SubtitleStreamIndex=-1)
""")

            // ── Targeted AudioCodec: use a single codec matching the selected stream ──
            // Listing "ac3,aac" can cause Emby to select the AAC track instead of AC3.
            // When the fallback is a known AC3/EAC3 track, pin to that codec only.
            let selectedCodec = (fallbackAudio?.codec ?? "").lowercased()
            let audioCodecString: String
            switch selectedCodec {
            case "ac3":        audioCodecString = "ac3"
            case "eac3":       audioCodecString = "eac3"
            default:           audioCodecString = "ac3,aac"
            }

            // Re-fetch — body carries AudioStreamIndex so Emby honours it
            var retryComps = try urlComponents(server, path: "/Items/\(itemId)/PlaybackInfo")
            var retryQuery: [URLQueryItem] = [.init(name: "UserId", value: userId)]
            if let audioIdx = fallbackAudio?.index {
                retryQuery.append(.init(name: "AudioStreamIndex", value: "\(audioIdx)"))
            }
            retryQuery.append(.init(name: "SubtitleStreamIndex", value: "-1"))
            retryComps.queryItems = retryQuery
            guard let retryURL = retryComps.url else { throw EmbyError.invalidURL }

            let retryBody = conservativeProfile(
                audioStreamIndex:    fallbackAudio?.index,
                subtitleStreamIndex: -1,
                audioCodec:          audioCodecString
            )

            // ── Log the full POST body before sending ──────────────────────────────
            if let bodyData = try? JSONSerialization.data(withJSONObject: retryBody, options: .prettyPrinted),
               let bodyStr  = String(data: bodyData, encoding: .utf8) {
                print("[Playback] 📤 Difficult-file re-fetch POST to: \(retryURL.absoluteString.prefix(120))")
                print("[Playback] 📤 POST body:\n\(bodyStr)")
            }

            if let retryInfo = try? decode(EmbyPlaybackInfo.self,
                                           from: try await postJSON(url: retryURL,
                                                                     body: retryBody,
                                                                     token: token)),
               let retrySource = retryInfo.mediaSources.first {
                let newTcUrl = retrySource.transcodingUrl ?? ""
                let oldTcUrl = source.transcodingUrl ?? ""
                refetchSucceeded = !newTcUrl.isEmpty
                activeSource     = retrySource
                activeSessionId  = retryInfo.playSessionId ?? UUID().uuidString

                // ── Validation + patch: did Emby honour our AudioStreamIndex? ──────
                if let requestedIdx = fallbackAudio?.index, !newTcUrl.isEmpty {
                    // Resolve to absolute URL so we can inspect and potentially patch it
                    let wasRelative = !newTcUrl.hasPrefix("http")
                    let absolute    = wasRelative ? server.url + newTcUrl : newTcUrl

                    if let absURL = URL(string: absolute) {
                        let returnedIdxStr = URLComponents(url: absURL, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name.lowercased() == "audiostreamindex" })?.value
                        let returnedIdx = returnedIdxStr.flatMap(Int.init)

                        let (patchedURL, wasPatched) = patchAudioStreamIndex(
                            url: absURL, requestedIndex: requestedIdx, context: "difficult-file refetch")

                        if wasPatched {
                            // ── Stream identity comparison — diagnose why Emby overrode ──
                            // Find the stream Emby actually selected so we can compare metadata.
                            let allRetryStreams = retrySource.mediaStreams ?? []

                            func streamDesc(_ s: EmbyMediaStream?) -> String {
                                guard let s else { return "unknown" }
                                let idx    = s.index.map { "#\($0)" } ?? "#?"
                                let codec  = s.codec ?? "?"
                                let ch     = s.channels.map { "\($0)ch" } ?? "?ch"
                                let layout = s.channelLayout.map { " \($0)" } ?? ""
                                let lang   = s.language.map { " lang=\($0)" } ?? " lang=?"
                                let disp   = s.displayTitle.map { " \"\($0)\"" } ?? ""
                                let def    = s.isDefault == true ? " [default]" : ""
                                let forced = s.isForced  == true ? " [forced]"  : ""
                                return "\(idx) | \(codec) | \(ch)\(layout)\(lang)\(disp)\(def)\(forced)"
                            }

                            let requestedStream = allRetryStreams.first(where: { $0.index == requestedIdx })
                            let returnedStream  = returnedIdx.flatMap { ri in
                                allRetryStreams.first(where: { $0.index == ri })
                            }

                            let requestedLang = requestedStream?.language?.lowercased() ?? "?"
                            let returnedLang  = returnedStream?.language?.lowercased()  ?? "?"
                            let likelyLangOverride = returnedLang != requestedLang
                                && (returnedLang == "eng" || returnedLang == "en")

                            print("""
[Playback] ⚠️ Stream identity comparison (Emby overrode our selection):
[Playback]   Requested (index=\(requestedIdx)): \(streamDesc(requestedStream))
[Playback]   Emby returned (index=\(returnedIdxStr ?? "?")): \(streamDesc(returnedStream))
[Playback]   Probable cause: \(likelyLangOverride
    ? "Emby overrode to user-preferred language (lang=\(returnedLang)) — patching back to requested track"
    : "Unknown override reason — patching back to requested track regardless")
[Playback]   → Patching URL: AC3/EAC3 compatibility takes priority on this fallback path.
[Playback]   → Future: expose per-item audio override so users can choose between tracks.
""")
                            // Store patched absolute URL — Rule 3 will pick this up
                            overrideTranscodingUrl = patchedURL.absoluteString
                        } else {
                            print("[Playback] ✅ AudioStreamIndex in URL: \(returnedIdxStr ?? "absent") — Emby honoured request")
                        }
                    }
                }

                let changed = newTcUrl != oldTcUrl
                print("[Playback] ✅ Re-fetch succeeded — TranscodingUrl \(changed ? "changed ✅" : "unchanged"): \(newTcUrl.prefix(80))")
            } else {
                print("[Playback] ⚠️ Re-fetch failed — continuing with original PlaybackInfo")
            }
        }

        let container  = activeSource.container ?? "unknown"
        let videoCodec = activeSource.videoStream?.codec ?? "unknown"
        let supportsDP          = activeSource.supportsDirectPlay
        let supportsDS          = activeSource.supportsDirectStream
        // Use patched URL if Emby returned wrong AudioStreamIndex; otherwise use source directly.
        let embyTranscodeUrl    = overrideTranscodingUrl ?? activeSource.transcodingUrl
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
[Playback] Stream re-fetch:      \(isDifficult ? (refetchSucceeded ? "✅ succeeded" : "⚠️ failed — using original") : "n/a")
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

        return PlaybackResult(
            url:                     url,
            playSessionId:           activeSessionId,
            mediaSourceId:           activeSource.id,
            playMethod:              playMethod,
            selectedSource:          activeSource,
            selectedAudioStreamIndex: selectedFallbackAudioIndex
        )
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Device Profiles
    // ─────────────────────────────────────────────────────────────────

    /// Conservative profile for difficult-file transcodes and AVPlayer retries.
    /// Forces H.264-only video (no HEVC passthrough).
    ///
    /// `audioCodec`: Use a single targeted codec (e.g. "ac3") when the selected
    /// fallback stream is known — listing multiple codecs (e.g. "ac3,aac") can
    /// cause Emby to pick a different track than requested.
    ///
    /// AudioStreamIndex / SubtitleStreamIndex are embedded directly in the POST
    /// body — Emby embeds them in the generated TranscodingUrl, whereas query-param
    /// versions are sometimes ignored depending on Emby server version.
    private static func conservativeProfile(
        audioStreamIndex:    Int?,
        subtitleStreamIndex: Int?,
        audioCodec:          String = "ac3,aac"
    ) -> [String: Any] {
        var body: [String: Any] = [
            "DeviceProfile": [
                "Name": "Pinea Apple TV 4K (H264 Conservative)",
                "MaxStreamingBitrate": 40_000_000,
                "DirectPlayProfiles":  [] as [[String: Any]],
                "TranscodingProfiles": [[
                    "Type":               "Video",
                    "Container":          "ts",
                    "VideoCodec":         "h264",
                    "AudioCodec":         audioCodec,
                    "Protocol":           "hls",
                    "Context":            "Streaming",
                    "MaxAudioChannels":   "6",
                    "BreakOnNonKeyFrames": true,
                    "MinSegments":        1
                ]] as [[String: Any]],
                "ContainerProfiles": [] as [[String: Any]],
                "CodecProfiles":     [] as [[String: Any]],
                "SubtitleProfiles":  [] as [[String: Any]]   // no subtitle burn-in
            ] as [String: Any]
        ]
        if let audioIdx = audioStreamIndex    { body["AudioStreamIndex"]    = audioIdx }
        if let subIdx   = subtitleStreamIndex { body["SubtitleStreamIndex"] = subIdx   }
        return body
    }

    // MARK: - URL patching helper

    /// Checks whether the given URL already has the correct AudioStreamIndex.
    /// If not, replaces it and logs a warning.
    /// Returns the (possibly patched) URL and a flag indicating whether a patch was applied.
    private static func patchAudioStreamIndex(
        url:            URL,
        requestedIndex: Int,
        context:        String = ""
    ) -> (url: URL, wasPatched: Bool) {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (url, false)
        }
        var items = comps.queryItems ?? []
        let key = "AudioStreamIndex"
        let currentVal = items.first(where: { $0.name.lowercased() == key.lowercased() })?.value

        guard currentVal != "\(requestedIndex)" else {
            return (url, false)   // already correct — no patch needed
        }

        let ctx = context.isEmpty ? "" : " (\(context))"
        print("[Playback] ⚠️ Emby returned wrong AudioStreamIndex=\(currentVal ?? "absent"); patching URL to requested AudioStreamIndex=\(requestedIndex)\(ctx)")
        items.removeAll { $0.name.lowercased() == key.lowercased() }
        items.append(.init(name: key, value: "\(requestedIndex)"))
        comps.queryItems = items
        return (comps.url ?? url, true)
    }

    // MARK: - Raw stream URL (PlayerLab path)

    /// Builds a static byte-range stream URL for PlayerLab's IO layer.
    ///
    /// PlayerLab reads the original container file via HTTP byte-range requests
    /// and handles all demuxing/decoding locally — no Emby transcoding required.
    ///
    /// Endpoint: GET /Videos/{itemId}/stream.{container}
    ///   ?Static=true          → return original file, no transcode
    ///   &MediaSourceId=...    → disambiguate when a title has multiple versions
    ///   &api_key=...          → authentication
    ///
    /// The Emby server sets Accept-Ranges: bytes on this endpoint, so MediaReader
    /// can issue arbitrary Range: bytes=N-M requests for seek/demux.
    ///
    /// Returns nil if the container is empty or the URL cannot be constructed.
    static func rawStreamURL(
        server:        EmbyServer,
        token:         String,
        itemId:        String,
        mediaSourceId: String,
        container:     String    // original container, e.g. "mkv", "mp4", "mov"
    ) -> URL? {
        let ext = container.lowercased().trimmingCharacters(in: .init(charactersIn: "."))
        guard !ext.isEmpty, !itemId.isEmpty else {
            print("[Playback] ⚠️ rawStreamURL: cannot build — ext='\(ext)' itemId='\(itemId)'")
            return nil
        }
        guard var comps = try? urlComponents(server, path: "/Videos/\(itemId)/stream.\(ext)") else {
            return nil
        }
        comps.queryItems = [
            .init(name: "MediaSourceId", value: mediaSourceId),
            .init(name: "Static",        value: "true"),
            .init(name: "api_key",       value: token),
        ]
        guard let url = comps.url else { return nil }
        print("[Playback] 🎬 PlayerLab raw stream URL: \(url.absoluteString.prefix(120))")
        return url
    }

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
                        "VideoCodec": "h264,hevc,h265",
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
    //
    // Called by the PlaybackEngine retry handler when the primary URL fails.
    // Fetches FRESH PlaybackInfo — never reuses the failed session — with:
    //   • Conservative H.264-only device profile (no HEVC passthrough risk)
    //   • AudioStreamIndex embedded in both POST body and query params
    //   • SubtitleStreamIndex=-1 (no burn-in)
    //
    // `preferredAudioStreamIndex` is the Emby MediaStream.Index of the best
    // AC3/EAC3 track selected during the original playbackURL() call.

    static func forcedTranscodeURL(
        server:                    EmbyServer,
        userId:                    String,
        token:                     String,
        itemId:                    String,
        preferredAudioStreamIndex: Int?    = nil,
        itemName:                  String  = ""
    ) async throws -> PlaybackResult {

        print("""
[Playback] 🆘 forcedTranscode for '\(itemName.isEmpty ? itemId : itemName)'
[Playback]   profile:                    H.264-only (conservative)
[Playback]   preferredAudioStreamIndex:  \(preferredAudioStreamIndex.map{"\($0)"} ?? "nil (default)")
[Playback]   SubtitleStreamIndex:        -1
""")

        // Fresh PlaybackInfo — new PlaySessionId, H.264-only profile
        var infoComps = try urlComponents(server, path: "/Items/\(itemId)/PlaybackInfo")
        var infoQuery: [URLQueryItem] = [.init(name: "UserId", value: userId)]
        if let audioIdx = preferredAudioStreamIndex {
            infoQuery.append(.init(name: "AudioStreamIndex", value: "\(audioIdx)"))
        }
        infoQuery.append(.init(name: "SubtitleStreamIndex", value: "-1"))
        infoComps.queryItems = infoQuery
        guard let infoURL = infoComps.url else { throw EmbyError.invalidURL }

        // For forcedTranscode, pin to a single targeted codec when we know the stream.
        // "ac3,aac" can cause Emby to drift to a different stream index.
        let forcedAudioCodec = "ac3"   // Always target AC3 on retry — it's our safest path

        let body = conservativeProfile(
            audioStreamIndex:    preferredAudioStreamIndex,
            subtitleStreamIndex: -1,
            audioCodec:          forcedAudioCodec
        )

        // ── Log the full POST body before sending ──────────────────────────────
        if let bodyData = try? JSONSerialization.data(withJSONObject: body, options: .prettyPrinted),
           let bodyStr  = String(data: bodyData, encoding: .utf8) {
            print("[Playback] 📤 forcedTranscode POST to: \(infoURL.absoluteString.prefix(120))")
            print("[Playback] 📤 POST body:\n\(bodyStr)")
        }

        let info = try decode(EmbyPlaybackInfo.self,
                              from: try await postJSON(url: infoURL, body: body, token: token))
        guard let source = info.mediaSources.first else { throw EmbyError.noMediaSource }

        let playSessionId = info.playSessionId ?? UUID().uuidString
        print("[Playback]   new PlaySessionId: \(playSessionId)")

        // Use Emby's TranscodingUrl — only append api_key if absent
        if let tcUrl = source.transcodingUrl {
            let wasRelative = !tcUrl.hasPrefix("http")
            let absolute    = wasRelative ? server.url + tcUrl : tcUrl
            if var comps = URLComponents(string: absolute) {
                var items = comps.queryItems ?? []
                if !items.contains(where: { $0.name == "api_key" }) {
                    items.append(.init(name: "api_key", value: token))
                }
                comps.queryItems = items
                if var url = comps.url {
                    // Audit the returned URL
                    let retVideoCodec = items.first(where: { $0.name.lowercased() == "videocodec"      })?.value ?? "?"
                    let retAudioCodec = items.first(where: { $0.name.lowercased() == "audiocodec"      })?.value ?? "?"
                    let retAudioIdx   = items.first(where: { $0.name.lowercased() == "audiostreamindex"})?.value ?? "?"
                    print("[Playback]   returned VideoCodec=\(retVideoCodec) AudioCodec=\(retAudioCodec) AudioStreamIndex=\(retAudioIdx) len=\(url.absoluteString.count)")

                    // ── Patch if Emby returned wrong AudioStreamIndex ──────────────
                    if let req = preferredAudioStreamIndex {
                        let (patched, wasPatched) = patchAudioStreamIndex(
                            url: url, requestedIndex: req, context: "forcedTranscode")
                        if wasPatched { url = patched }
                    }

                    return PlaybackResult(
                        url:                     url,
                        playSessionId:           playSessionId,
                        mediaSourceId:           source.id,
                        playMethod:              "Transcode",
                        selectedSource:          nil,
                        selectedAudioStreamIndex: preferredAudioStreamIndex
                    )
                }
            }
        }

        // Emergency manual HLS fallback — only if Emby gave no TranscodingUrl
        print("[Playback] 🚨 forcedTranscode EMERGENCY: no TranscodingUrl — constructing manual H.264 HLS fallback")
        var comps = try urlComponents(server, path: "/Videos/\(itemId)/master.m3u8")
        var queryItems: [URLQueryItem] = [
            .init(name: "MediaSourceId",   value: source.id),
            .init(name: "api_key",         value: token),
            .init(name: "DeviceId",        value: "cinemascope-appletv"),
            .init(name: "PlaySessionId",   value: playSessionId),
            .init(name: "VideoCodec",      value: "h264"),
            .init(name: "AudioCodec",      value: "ac3,aac"),
            .init(name: "MaxVideoBitrate", value: "8000000"),
            .init(name: "AudioBitrate",    value: "192000"),
            .init(name: "AudioChannels",   value: "6"),
            .init(name: "MaxWidth",        value: "1920"),
            .init(name: "MaxHeight",       value: "1080"),
            .init(name: "SubtitleStreamIndex", value: "-1"),
        ]
        if let audioIdx = preferredAudioStreamIndex {
            queryItems.append(.init(name: "AudioStreamIndex", value: "\(audioIdx)"))
        }
        comps.queryItems = queryItems
        guard let url = comps.url else { throw EmbyError.invalidURL }
        print("[Playback] 🚨 forcedTranscode emergency URL len=\(url.absoluteString.count)")
        return PlaybackResult(
            url:                     url,
            playSessionId:           playSessionId,
            mediaSourceId:           source.id,
            playMethod:              "Transcode",
            selectedSource:          nil,
            selectedAudioStreamIndex: preferredAudioStreamIndex
        )
    }
}
