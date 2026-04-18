// MARK: - PlayerLab / Audio / PremiumAudioPolicy
// Sprint 31 — Centralized premium-audio decision layer.
// Sprint 33 — Extended with DTS-Core passthrough path.
// Sprint 34 — useTrueHDAC3Core action for embedded AC3 extraction.
//
// All premium-audio decisions flow through this file.
// The controller and ContainerPreparation never embed audio-decision logic
// directly; they call PremiumAudioPolicy.decide() and act on the result.
//
// Responsibilities:
//   1. Classify every audio track (supported / DTS-Core attempt / unsupported / unknown)
//   2. Given available tracks + preference policy, return a deterministic action
//   3. Generate structured log messages for every decision step
//   4. Signal when AVPlayer fallback is recommended (no playable track found)
//
// Action hierarchy:
//   useDirect          — a fully-supported track was found; decode directly
//   useFallback        — preferred/default track unsupported; downgraded to a
//                        supported alternative (e.g. TrueHD → AC3 core)
//   attemptPassthrough — Sprint 33: DTS-Core track found; attempt hardware
//                        passthrough via kAudioFormatDTS; may yield silence on
//                        devices without DTS hardware
//   useTrueHDAC3Core   — Sprint 34: A_TRUEHD track probed and contains an AC3
//                        core; extract AC3 frames inline during demux
//   fallbackToAVPlayer — no playable track exists; caller should route the
//                        entire file to AVPlayer
//   videoOnly          — file contains no audio tracks at all
//
// NOT production-ready. Debug / lab use only.

import Foundation

// MARK: - AudioTrackClassification

/// How a single audio track is classified by PremiumAudioPolicy.
enum AudioTrackClassification {

    /// Fully supported: AAC, AC3, E-AC3.
    case supported(codec: String)

    /// Sprint 33: DTS-Core (A_DTS) — passthrough attempt via kAudioFormatDTS.
    /// May yield silence on devices without DTS-capable hardware.
    case dtsCoreAttempt

    /// Codec is recognized but cannot currently be decoded or passed through.
    /// Includes TrueHD, DTS-HD MA, and unhandled DTS variants.
    case unsupported(codec: String, reason: String)

    /// Codec ID is not recognized by PlayerLab.
    case unknown(codecID: String)

    /// Human-readable label for logging.
    var label: String {
        switch self {
        case .supported(let c):          return "\(c) ✅"
        case .dtsCoreAttempt:            return "DTS-Core ⚠️ (passthrough attempt)"
        case .unsupported(let c, _):     return "\(c) ❌ unsupported"
        case .unknown(let id):           return "\(id) ❓ unknown"
        }
    }

    /// True when the classification implies the track can be played (possibly with caveats).
    var isPlayable: Bool {
        switch self {
        case .supported, .dtsCoreAttempt: return true
        case .unsupported, .unknown:      return false
        }
    }
}

// MARK: - AudioPlaybackAction

/// The action PlayerLab should take for audio after the decision is made.
enum AudioPlaybackAction: Equatable {

    /// A fully-supported track is selected; decode directly.
    case useDirect(trackNumber: UInt64)

    /// Preferred / default track is unsupported; a compatible fallback was found.
    case useFallback(trackNumber: UInt64, from originalCodec: String, to fallbackCodec: String)

    /// Sprint 33: DTS-Core is the best available audio; attempt hardware passthrough.
    case attemptPassthrough(trackNumber: UInt64, codec: String)

    /// Sprint 34: A_TRUEHD track was probed and contains an embedded AC3 core.
    /// ContainerPreparation enables inline AC3 extraction on the demuxer; the
    /// controller treats this track like a native AC3 track from this point on.
    case useTrueHDAC3Core(trackNumber: UInt64)

    /// No playable audio track exists in PlayerLab; caller should route to AVPlayer.
    case fallbackToAVPlayer(reason: String)

    /// File has no audio tracks.
    case videoOnly

    // MARK: Convenience

    /// Track number to configure the demuxer and feeder for, or nil for audioless paths.
    var selectedTrackNumber: UInt64? {
        switch self {
        case .useDirect(let n):             return n
        case .useFallback(let n, _, _):     return n
        case .attemptPassthrough(let n, _): return n
        case .useTrueHDAC3Core(let n):      return n
        default:                            return nil
        }
    }

    /// True when the file should be handed off to AVPlayer entirely.
    var requiresAVPlayer: Bool {
        if case .fallbackToAVPlayer = self { return true }
        return false
    }

    public static func == (lhs: AudioPlaybackAction, rhs: AudioPlaybackAction) -> Bool {
        switch (lhs, rhs) {
        case (.videoOnly, .videoOnly):                                              return true
        case (.useDirect(let a), .useDirect(let b)):                                return a == b
        case (.useFallback(let a, _, _), .useFallback(let b, _, _)):                return a == b
        case (.attemptPassthrough(let a, _), .attemptPassthrough(let b, _)):        return a == b
        case (.useTrueHDAC3Core(let a), .useTrueHDAC3Core(let b)):                  return a == b
        case (.fallbackToAVPlayer(let a), .fallbackToAVPlayer(let b)):              return a == b
        default:                                                                     return false
        }
    }
}

// MARK: - AudioPlaybackDecision

/// Complete result returned by PremiumAudioPolicy.decide().
/// Carries both the action enum and the ordered log messages that explain it.
struct AudioPlaybackDecision {
    let action:      AudioPlaybackAction
    let logMessages: [String]

    /// Convenience — true when AVPlayer is recommended for this file.
    var requiresAVPlayerFallback: Bool { action.requiresAVPlayer }

    /// Convenience — track number to tell the demuxer to use, or nil.
    var selectedTrackNumber: UInt64? { action.selectedTrackNumber }
}

// MARK: - PremiumAudioPolicy

/// Stateless entry point for all premium-audio decisions.
///
/// Usage (in ContainerPreparation.prepareMKV):
/// ```swift
/// let decision = PremiumAudioPolicy.decide(
///     tracks:               mkv.availableAudioTracks,
///     preferredTrackNumber: preferredAudioTrack,
///     preferencePolicy:     audioPolicy)
/// for msg in decision.logMessages { logs.append(msg) }
/// // act on decision.action …
/// ```
struct PremiumAudioPolicy {

    // MARK: - Track classification

    /// Classify a single track by its codec ID.
    static func classify(_ track: MKVAudioTrackDescriptor) -> AudioTrackClassification {
        if track.isAAC   { return .supported(codec: "AAC")   }
        if track.isAC3   { return .supported(codec: "AC3")   }
        if track.isEAC3  { return .supported(codec: "E-AC3") }

        // Sprint 33: DTS-Core passthrough attempt (A_DTS exact match only)
        if track.isDTSCore { return .dtsCoreAttempt }

        if track.isTrueHD {
            return .unsupported(codec: "TrueHD",
                reason: "no Apple decoder; requires AC3 core extraction or HDMI passthrough")
        }
        // DTS-HD variants (A_DTS/HRA, A_DTS/LOSSLESS, etc.)
        if track.isDTSHD {
            return .unsupported(codec: "DTS-HD (\(track.codecID))",
                reason: "lossless/HD DTS not decodable via Apple frameworks")
        }
        // Any remaining A_DTS* not caught above
        if track.isDTS {
            return .unsupported(codec: "DTS (\(track.codecID))",
                reason: "DTS variant not recognized for passthrough")
        }
        return .unknown(codecID: track.codecID)
    }

    // MARK: - Primary decision entry point

    /// Determine the playback action for an MKV file's audio tracks.
    ///
    /// - Parameters:
    ///   - tracks:               All audio tracks discovered by MKVDemuxer.
    ///   - preferredTrackNumber: Explicit user override (nil = use policy).
    ///   - preferencePolicy:     Language/codec preference for automatic selection.
    /// - Returns: `AudioPlaybackDecision` with action + ordered log messages.
    static func decide(
        tracks:               [MKVAudioTrackDescriptor],
        preferredTrackNumber: UInt64?,
        preferencePolicy:     AudioPreferencePolicy
    ) -> AudioPlaybackDecision {

        var logs: [String] = []

        // ── No audio tracks ───────────────────────────────────────────────────
        if tracks.isEmpty {
            logs.append("[Audio] No audio tracks in file — video only")
            return AudioPlaybackDecision(action: .videoOnly, logMessages: logs)
        }

        // ── Log all tracks with classification ────────────────────────────────
        for t in tracks {
            let cls = classify(t)
            logs.append("[Audio] Track \(t.trackNumber): \(t.codecID)  "
                      + "ch=\(t.channelCount)  sr=\(Int(t.sampleRate)) Hz  "
                      + "lang=\(t.language)\(t.isDefault ? " [default]" : "")  "
                      + "→ \(cls.label)")
        }

        let supportedTracks = tracks.filter { $0.isSupported }

        // ── Case A: Explicit preferred track ─────────────────────────────────
        if let preferred = preferredTrackNumber,
           let preferredDesc = tracks.first(where: { $0.trackNumber == preferred }) {

            let cls = classify(preferredDesc)
            if case .supported = cls {
                logs.append("[Audio] Requested track \(preferred) (\(preferredDesc.codecID)) — supported, using directly")
                return AudioPlaybackDecision(action: .useDirect(trackNumber: preferred),
                                             logMessages: logs)
            }

            // Preferred track is not directly supported — look for a reliable fallback
            logs.append("[Audio] Requested track \(preferred) (\(preferredDesc.codecID)) — \(cls.label)")

            if let fallback = findBestFallback(preferredLanguage: preferredDesc.language,
                                                from: supportedTracks) {
                logs.append("[Audio] Found \(fallback.codecID) fallback (track \(fallback.trackNumber)) — switching")
                return AudioPlaybackDecision(
                    action: .useFallback(trackNumber:   fallback.trackNumber,
                                         from:          preferredDesc.codecID,
                                         to:            fallback.codecID),
                    logMessages: logs)
            }

            // Sprint 33: no reliable fallback — try DTS-Core passthrough
            if let dts = dtsCoreCandidate(preferredLanguage: preferredDesc.language, from: tracks) {
                logs.append("[Audio] No reliable fallback; attempting DTS-Core via passthrough (track \(dts.trackNumber))")
                return AudioPlaybackDecision(
                    action: .attemptPassthrough(trackNumber: dts.trackNumber, codec: "DTS-Core"),
                    logMessages: logs)
            }

            logs.append("[Audio] No compatible fallback for \(preferredDesc.codecID) — recommend AVPlayer")
            return AudioPlaybackDecision(
                action: .fallbackToAVPlayer(reason: "\(preferredDesc.codecID) unsupported, no fallback"),
                logMessages: logs)
        }

        // ── Case B: Policy-based automatic selection ──────────────────────────
        //
        // Determine whether a "natural first choice" track (default-flagged, or
        // first track in the file) is unsupported, so we can log the fallback.
        let naturalFirst = tracks.first(where: { $0.isDefault }) ?? tracks.first
        let naturalIsUnsupported = naturalFirst.map { !$0.isSupported } ?? false

        if let best = AudioTrackSelector.select(from: supportedTracks, policy: preferencePolicy) {
            if naturalIsUnsupported, let natural = naturalFirst {
                logs.append("[Audio] \(natural.codecID) (track \(natural.trackNumber)) unsupported "
                          + "— fallback to \(best.codecID) (track \(best.trackNumber))")
                return AudioPlaybackDecision(
                    action: .useFallback(trackNumber: best.trackNumber,
                                         from:        natural.codecID,
                                         to:          best.codecID),
                    logMessages: logs)
            }
            let reason = AudioTrackSelector.selectionReason(for: best, policy: preferencePolicy)
            logs.append("[Audio] Selected track \(best.trackNumber) (\(best.codecID)) — \(reason)")
            return AudioPlaybackDecision(action: .useDirect(trackNumber: best.trackNumber),
                                         logMessages: logs)
        }

        // No supported tracks at all.
        // Sprint 33: check for DTS-Core passthrough candidate.
        if let dts = dtsCoreCandidate(preferredLanguage: preferencePolicy.preferredLanguage,
                                       from: tracks) {
            logs.append("[Audio] No supported tracks; attempting DTS-Core via passthrough (track \(dts.trackNumber))")
            return AudioPlaybackDecision(
                action: .attemptPassthrough(trackNumber: dts.trackNumber, codec: "DTS-Core"),
                logMessages: logs)
        }

        let codecList = tracks.map { $0.codecID }.joined(separator: ", ")
        logs.append("[Audio] No compatible audio track (\(codecList)) — recommend AVPlayer")
        return AudioPlaybackDecision(
            action: .fallbackToAVPlayer(reason: "no supported audio (\(codecList))"),
            logMessages: logs)
    }

    // MARK: - Fallback search helpers

    /// Best fully-supported track ordered by: language match > codec reliability
    /// (E-AC3 > AC3 > AAC) > default flag > channel count.
    static func findBestFallback(
        preferredLanguage: String?,
        from supportedTracks: [MKVAudioTrackDescriptor]
    ) -> MKVAudioTrackDescriptor? {
        guard !supportedTracks.isEmpty else { return nil }
        return supportedTracks.max {
            fallbackScore($0, preferredLanguage: preferredLanguage) <
            fallbackScore($1, preferredLanguage: preferredLanguage)
        }
    }

    // MARK: - Sprint 33: DTS-Core candidate selection

    /// Returns the best A_DTS (standard DTS-Core) track for passthrough attempt.
    /// Returns nil if no standard DTS-Core tracks exist, or if a supported
    /// (AAC/AC3/EAC3) track is also present (reliable tracks take priority).
    static func dtsCoreCandidate(
        preferredLanguage: String?,
        from tracks: [MKVAudioTrackDescriptor]
    ) -> MKVAudioTrackDescriptor? {
        // Only consider DTS-Core when there are no fully-supported alternatives.
        guard tracks.filter({ $0.isSupported }).isEmpty else { return nil }

        let dtsCandidates = tracks.filter { $0.isDTSCore }
        guard !dtsCandidates.isEmpty else { return nil }

        return dtsCandidates.max {
            fallbackScore($0, preferredLanguage: preferredLanguage) <
            fallbackScore($1, preferredLanguage: preferredLanguage)
        }
    }

    // MARK: - Sprint 34: TrueHD probe candidate selection

    /// Returns a TrueHD track number to probe for an embedded AC3 core, or nil.
    ///
    /// A TrueHD track is only offered for probing when:
    ///   • No fully-supported (AAC/AC3/EAC3) tracks exist.
    ///   • No DTS-Core passthrough candidate exists.
    ///   • At least one A_TRUEHD track is present.
    ///
    /// If the probe succeeds, ContainerPreparation replaces the `fallbackToAVPlayer`
    /// decision with `.useTrueHDAC3Core`.
    static func trueHDTrackToProbe(
        in tracks: [MKVAudioTrackDescriptor]
    ) -> UInt64? {
        // Only probe TrueHD when there is no other PlayerLab-playable option.
        guard tracks.filter({ $0.isSupported }).isEmpty else { return nil }
        guard tracks.filter({ $0.isDTSCore  }).isEmpty else { return nil }

        // Prefer the default-flagged TrueHD track; fall back to the first one.
        let trueHDTracks = tracks.filter { $0.isTrueHD }
        guard !trueHDTracks.isEmpty else { return nil }

        let candidate = trueHDTracks.first(where: { $0.isDefault }) ?? trueHDTracks[0]
        return candidate.trackNumber
    }

    // MARK: - Scoring (private)

    private static func fallbackScore(_ t: MKVAudioTrackDescriptor,
                                       preferredLanguage: String?) -> Int {
        var s = 0
        if let lang = preferredLanguage,
           t.language.lowercased() == lang.lowercased() { s += 1000 }
        if t.isEAC3 { s += 300 }
        else if t.isAC3 { s += 200 }
        else if t.isAAC { s += 100 }
        if t.isDefault   { s += 10  }
        s += min(t.channelCount, 8)
        return s
    }
}
