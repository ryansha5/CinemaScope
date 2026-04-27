// MARK: - Core / Playback / PlaybackRouteDecision
// Sprint 41 — Playback routing confidence layer.
//
// A single, deterministic routing module that evaluates media attributes
// and returns a typed decision: PlayerLab or AVPlayer.
//
// Design goals:
//   • Pure logic — no side effects, no async, no I/O.
//   • Takes EmbyMediaSource (codec facts from the server) + playMethod.
//   • Falls back gracefully when source info is unavailable.
//   • Conservative by default — unknown = AVPlayer.
//
// PlayerLab support matrix (as of Sprint 43):
//   Container: mp4 / mov / mkv / webm (raw file, direct-play only)
//   Video:     H.264 (avc, avc1, h264) / HEVC (hevc, h265, hvc1, hev1)
//   Audio:     AAC / AC3 / EAC3                   → high confidence
//              TrueHD (AC3 core extraction)         → medium confidence
//              DTS-Core on tvOS (passthrough)        → medium confidence
//              DTS-HD MA / DTS:X / unknown premium   → AVPlayer required
//   Subtitles: SRT, PGS — handled natively; others silently skipped (no penalty)
//   PlayMethod: DirectPlay only — HLS transcodes and remuxed streams cannot be
//               parsed by PlayerLab's byte-range demuxer.
//
// NOT production-ready. Route quality improves over sprints.

import Foundation

// MARK: - PlaybackConfidence

/// How confident we are that PlayerLab can fully play a piece of content.
enum PlaybackConfidence: Int, Comparable, CaseIterable {
    case low    = 0   // might work; risk of silent failure or codec mismatch
    case medium = 1   // likely works; one or more speculative decode paths active
    case high   = 2   // all codecs are deterministically supported

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .low:    return "low"
        case .medium: return "medium"
        case .high:   return "high"
        }
    }
}

// MARK: - PlaybackRoute

/// Deterministic routing decision for a single piece of content.
enum PlaybackRoute {

    /// PlayerLab should handle this content.
    /// `confidence` indicates how certain we are; see PlaybackConfidence.
    case usePlayerLab(reason: String, confidence: PlaybackConfidence)

    /// AVPlayer should handle this content.
    case useAVPlayer(reason: String)

    // MARK: Convenience

    var isPlayerLab: Bool {
        if case .usePlayerLab = self { return true }
        return false
    }

    var confidence: PlaybackConfidence? {
        if case .usePlayerLab(_, let c) = self { return c }
        return nil
    }

    /// A single-line log string suitable for print() / record().
    var logLine: String {
        switch self {
        case .usePlayerLab(let r, let c):
            return "[Route] PlayerLab (\(c.label)) — \(r)"
        case .useAVPlayer(let r):
            return "[Route] AVPlayer — \(r)"
        }
    }

    /// True if confidence is at or above the given threshold.
    func meetsThreshold(_ threshold: PlaybackConfidence) -> Bool {
        switch self {
        case .usePlayerLab(_, let c): return c >= threshold
        case .useAVPlayer:            return false
        }
    }
}

// MARK: - PlaybackRouter

/// Evaluates media attributes and returns a PlaybackRoute.
/// All decisions are deterministic given the same inputs.
enum PlaybackRouter {

    // MARK: - Supported codec sets

    /// Video codecs PlayerLab can decode (H.264 and HEVC via VideoToolbox).
    private static let supportedVideoCodecs: Set<String> = [
        "h264", "avc", "avc1",
        "hevc", "h265", "hvc1", "hev1"
    ]

    /// Containers PlayerLab can parse (raw demux, no HLS/TS handling).
    private static let supportedContainers: Set<String> = [
        "mp4", "m4v", "mov",
        "mkv", "webm"
    ]

    /// Audio codecs for which PlayerLab has a fully-reliable decode path.
    private static let highConfidenceAudioCodecs: Set<String> = [
        "aac", "ac3", "eac3"
    ]

    // MARK: - Main entry

    /// Returns the recommended playback route for the given media.
    ///
    /// - Parameters:
    ///   - source:           The selected Emby media source. May be nil when
    ///                       stream info is unavailable before the playback URL
    ///                       request is made.
    ///   - playMethod:       Emby's chosen playback method: "DirectPlay",
    ///                       "DirectStream", or "Transcode".
    ///   - url:              The resolved playback URL. Used as a container
    ///                       fallback (via file extension) when `source` is nil.
    ///   - playerLabEnabled: Master on/off toggle from AppSettings.
    ///
    /// - Returns: A deterministic `PlaybackRoute` with an explanatory reason string.
    static func decide(
        source:           EmbyMediaSource?,
        playMethod:       String,
        url:              URL,
        playerLabEnabled: Bool
    ) -> PlaybackRoute {

        // ── Guard: feature flag ───────────────────────────────────────────────
        guard playerLabEnabled else {
            return .useAVPlayer(reason: "PlayerLab disabled in settings")
        }

        // ── Guard: direct-play only ───────────────────────────────────────────
        // PlayerLab's byte-range demuxer requires a raw seekable file stream.
        // Transcoded HLS (.m3u8) and remuxed DirectStream paths cannot be parsed.
        guard playMethod == "DirectPlay" else {
            return .useAVPlayer(
                reason: "playMethod=\(playMethod) — PlayerLab requires DirectPlay raw stream")
        }

        // ── Container check ───────────────────────────────────────────────────
        let rawContainer  = source?.container ?? url.pathExtension
        let container     = rawContainer.lowercased()
        guard !container.isEmpty, supportedContainers.contains(container) else {
            let label = container.isEmpty ? "unknown" : container
            return .useAVPlayer(reason: "Unsupported container '\(label)'")
        }

        // ── Video codec check ─────────────────────────────────────────────────
        let rawVideoCodec = source?.videoStream?.codec ?? ""
        let videoCodec    = rawVideoCodec.lowercased()
        guard !videoCodec.isEmpty, supportedVideoCodecs.contains(videoCodec) else {
            let label = videoCodec.isEmpty ? "unknown" : videoCodec
            return .useAVPlayer(reason: "Unsupported video codec '\(label)'")
        }

        // ── Audio analysis ────────────────────────────────────────────────────
        let audioResult = classifyAudio(from: source, container: container)
        if audioResult.avPlayerRequired {
            return .useAVPlayer(reason: audioResult.label)
        }

        // ── Build route ───────────────────────────────────────────────────────
        let contLabel  = container.uppercased()
        let vidLabel   = canonicalVideoLabel(videoCodec)
        let reason     = "\(contLabel) \(vidLabel) \(audioResult.label)"

        return .usePlayerLab(reason: reason, confidence: audioResult.confidence)
    }

    // MARK: - Audio classification

    private struct AudioClassification {
        let confidence:      PlaybackConfidence
        let label:           String
        let avPlayerRequired: Bool
    }

    /// Classifies the audio tracks in a media source to determine PlayerLab
    /// compatibility and confidence.
    ///
    /// Priority:
    ///   1. Any high-confidence track (AAC/AC3/EAC3) → high confidence.
    ///   2. TrueHD present (AC3 core extraction path) → medium confidence.
    ///   3. DTS-Core only → medium on tvOS (passthrough), AVPlayer elsewhere.
    ///   4. DTS-HD MA / DTS:X / unknown → AVPlayer required.
    ///   5. No audio tracks → high confidence (video-only is fine).
    ///   6. No source info → medium (conservative for unknown containers).
    private static func classifyAudio(
        from source: EmbyMediaSource?,
        container:   String
    ) -> AudioClassification {

        guard let source = source else {
            // No Emby stream info at all — use container heuristic.
            // MP4 almost always has AAC; MKV is less predictable.
            if ["mp4", "m4v", "mov"].contains(container) {
                return AudioClassification(confidence: .high, label: "AAC (assumed, no stream info)", avPlayerRequired: false)
            }
            return AudioClassification(confidence: .medium, label: "audio unknown (no stream info)", avPlayerRequired: false)
        }

        let streams = source.audioStreams
        guard !streams.isEmpty else {
            return AudioClassification(confidence: .high, label: "no audio tracks", avPlayerRequired: false)
        }

        let codecs = streams.compactMap { $0.codec?.lowercased() }

        // 1. High-confidence audio present?
        let highConfCodecs = codecs.filter { highConfidenceAudioCodecs.contains($0) }
        if !highConfCodecs.isEmpty {
            let label = highConfCodecs.uniqued().joined(separator: "+")
            return AudioClassification(confidence: .high, label: label, avPlayerRequired: false)
        }

        // 2. TrueHD (Dolby TrueHD or MLP-based) — AC3 core extraction path.
        let hasTrueHD = codecs.contains { $0 == "truehd" || $0 == "mlp" }
        if hasTrueHD {
            return AudioClassification(
                confidence:      .medium,
                label:           "TrueHD (AC3 core extraction)",
                avPlayerRequired: false
            )
        }

        // 3. DTS-Core — hardware passthrough on tvOS; not supported elsewhere.
        let hasDTSCore = codecs.contains { $0 == "dts" }
        if hasDTSCore {
            if DTSCapabilityHeuristic.isLikelyCapable {
                return AudioClassification(
                    confidence:      .medium,
                    label:           "DTS-Core (tvOS passthrough)",
                    avPlayerRequired: false
                )
            } else {
                return AudioClassification(
                    confidence:      .low,
                    label:           "DTS-Core not supported on this platform — AVPlayer required",
                    avPlayerRequired: true
                )
            }
        }

        // 4. DTS-HD MA / DTS:X / other high-end audio — AVPlayer required.
        //    Any remaining unrecognised codec is treated as unsupported.
        let unsupportedCodecs = codecs.filter { c in
            !highConfidenceAudioCodecs.contains(c) && c != "truehd" && c != "mlp" && c != "dts"
        }
        if !unsupportedCodecs.isEmpty {
            let label = unsupportedCodecs.uniqued().joined(separator: "/")
            return AudioClassification(
                confidence:      .high,
                label:           "Unsupported premium audio '\(label)' — AVPlayer required",
                avPlayerRequired: true
            )
        }

        // Shouldn't reach here, but be conservative.
        return AudioClassification(
            confidence:      .low,
            label:           "Unknown audio configuration",
            avPlayerRequired: false
        )
    }

    // MARK: - PlayerLab raw-stream evaluation (playMethod-independent)

    /// Evaluates PlayerLab compatibility purely from media metadata, ignoring
    /// Emby's `playMethod`.
    ///
    /// Used when we want to route to PlayerLab using a raw static stream
    /// (`/Videos/{id}/stream.mkv?Static=true`) even when Emby's PlaybackInfo
    /// says `playMethod = "Transcode"`.
    ///
    /// Emby's DirectPlay / DirectStream flags describe what *AVPlayer* can play
    /// natively — they have no bearing on PlayerLab's byte-range demuxer.
    /// For files like "All Quiet on the Western Front" (MKV HEVC TrueHD PGS),
    /// Emby says "Transcode" because it knows AVPlayer can't handle TrueHD over
    /// HLS. PlayerLab reads the raw MKV bytes via HTTP Range and demuxes locally,
    /// so the transcode opinion is irrelevant.
    ///
    /// Container / codec / audio checks are identical to `decide()`.
    static func evaluateForPlayerLab(
        source:           EmbyMediaSource?,
        playerLabEnabled: Bool
    ) -> PlaybackRoute {

        guard playerLabEnabled else {
            return .useAVPlayer(reason: "PlayerLab disabled in settings")
        }
        guard let source else {
            return .useAVPlayer(reason: "No media source — cannot evaluate for PlayerLab raw stream")
        }

        // ── Container ────────────────────────────────────────────────────────
        let rawContainer = source.container ?? ""
        let container    = rawContainer.lowercased()
        guard !container.isEmpty, supportedContainers.contains(container) else {
            let label = container.isEmpty ? "unknown" : container
            return .useAVPlayer(reason: "Container '\(label)' not supported by PlayerLab raw stream")
        }

        // ── Video codec ──────────────────────────────────────────────────────
        let rawVideoCodec = source.videoStream?.codec ?? ""
        let videoCodec    = rawVideoCodec.lowercased()
        guard !videoCodec.isEmpty, supportedVideoCodecs.contains(videoCodec) else {
            let label = videoCodec.isEmpty ? "unknown" : videoCodec
            return .useAVPlayer(reason: "Video codec '\(label)' not supported by PlayerLab")
        }

        // ── Audio ─────────────────────────────────────────────────────────────
        let audioResult = classifyAudio(from: source, container: container)
        if audioResult.avPlayerRequired {
            return .useAVPlayer(reason: "Audio: \(audioResult.label) — PlayerLab cannot handle")
        }

        // ── Route ─────────────────────────────────────────────────────────────
        let contLabel = container.uppercased()
        let vidLabel  = canonicalVideoLabel(videoCodec)
        let reason    = "PlayerLab candidate — \(contLabel) \(vidLabel) \(audioResult.label) (raw stream, bypass Emby transcode)"
        return .usePlayerLab(reason: reason, confidence: audioResult.confidence)
    }

    // MARK: - Helpers

    /// Returns a short human-readable codec label for display in route logs.
    private static func canonicalVideoLabel(_ codec: String) -> String {
        switch codec {
        case "h264", "avc", "avc1": return "H.264"
        case "hevc", "h265", "hvc1", "hev1": return "HEVC"
        default: return codec.uppercased()
        }
    }
}

// MARK: - Array+Uniqued (local utility)

private extension Array where Element: Hashable {
    /// Returns the array without duplicates, preserving order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
