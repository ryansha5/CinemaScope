// MARK: - PlayerLab / Audio / PlayerLabAudioPreferences
//
// Sprint 25 — Audio track preference policy and deterministic track selection.
//
// Design:
//   AudioPreferencePolicy  — value-type configuration: language, codec tier, default-flag respect.
//   AudioTrackSelector     — stateless function: apply policy to an ordered track list.
//
// Usage:
//   let policy   = AudioPreferencePolicy.language("eng", codec: .surround)
//   let selected = AudioTrackSelector.select(from: mkv.availableAudioTracks, policy: policy)
//
// Sprint 25 scope: restart-based switching only (full re-prepare at saved position).
// Seamless live switching may be added in a later sprint.

import Foundation

// MARK: - AudioCodecPreference

/// Codec tier preference for audio track selection.
enum AudioCodecPreference: String, CaseIterable {
    /// Prefer AAC — broadest device compatibility, always decodable on-device.
    case compatibility = "compatibility"
    /// Prefer AC3 / EAC3 — best for 5.1/7.1 setups via HDMI pass-through.
    case surround      = "surround"
    /// No codec preference — apply only language and default-flag criteria.
    case any           = "any"
}

// MARK: - AudioPreferencePolicy

/// Value type that describes how to pick the best available audio track.
struct AudioPreferencePolicy: Equatable {

    /// ISO 639-2 language code (e.g. "eng", "fre", "jpn").
    /// nil = no language filter — any language is acceptable.
    var preferredLanguage: String? = nil

    /// Codec tier to prefer within a matching language group.
    var codecPreference: AudioCodecPreference = .compatibility

    /// When true, a default-flagged track is preferred as a tiebreaker.
    var respectDefaultFlag: Bool = true

    // MARK: - Factory presets

    /// System default: respect default flag, prefer AAC, no language filter.
    static let `default` = AudioPreferencePolicy()

    /// Prefer surround (EAC3 > AC3 > AAC), optional language match.
    static func surround(language: String? = nil) -> AudioPreferencePolicy {
        AudioPreferencePolicy(preferredLanguage: language,
                               codecPreference:   .surround,
                               respectDefaultFlag: true)
    }

    /// Prefer a specific language, optional codec tier.
    static func language(_ code: String,
                          codec: AudioCodecPreference = .compatibility) -> AudioPreferencePolicy {
        AudioPreferencePolicy(preferredLanguage: code,
                               codecPreference:   codec,
                               respectDefaultFlag: true)
    }
}

// MARK: - AudioTrackSelector

/// Stateless helper that scores `MKVAudioTrackDescriptor` candidates against a policy
/// and returns the best match.
struct AudioTrackSelector {

    // MARK: - Selection

    /// Returns the highest-scoring supported track for the given policy.
    /// Returns nil only when `candidates` contains no supported tracks.
    static func select(from candidates: [MKVAudioTrackDescriptor],
                        policy: AudioPreferencePolicy) -> MKVAudioTrackDescriptor? {
        let supported = candidates.filter { $0.isSupported }
        guard !supported.isEmpty else { return nil }
        return supported.max(by: { score($0, policy: policy) < score($1, policy: policy) })
    }

    // MARK: - Sprint 29: Strategy documentation
    //
    // TrueHD and DTS/DTS-HD tracks are detected by MKVAudioTrackDescriptor.classification
    // but are NOT decoded by PlayerLab.  Future options:
    //
    //   TrueHD:
    //     • Apple does not expose a public TrueHD decoder.
    //     • Option A: Extract core AC3 (many TrueHD streams contain an embedded AC3 core).
    //     • Option B: HDMI passthrough via AVAudioSession (.playAndRecord + HDMI route).
    //     • Option C: Software decode using a third-party library (out of scope).
    //
    //   DTS / DTS-HD:
    //     • DTS-Core (DTS) IS supported via kAudioFormatDTS on supported hardware.
    //     • DTS-HD MA (lossless) has no Apple decoder path; fall back to DTS-Core.
    //     • kAudioFormatDTS requires hardware support (ATV, Mac with HDMI out).
    //     • Recommend: detect DTS-Core availability at runtime; fall back to video-only.
    //
    //   Recommended implementation order (future sprints):
    //     1. DTS-Core passthrough (highest impact, partial framework support)
    //     2. TrueHD→AC3 core extraction
    //     3. TrueHD HDMI passthrough
    //
    //   Until implemented, AudioTrackSelector.select() skips these tracks entirely
    //   (isSupported = false), and PlayerLab falls back to video-only playback.

    // MARK: - Reason string (for structured logging)

    /// Human-readable explanation of why `track` was selected under `policy`.
    static func selectionReason(for track: MKVAudioTrackDescriptor,
                                 policy: AudioPreferencePolicy) -> String {
        var reasons = [String]()
        if let lang = policy.preferredLanguage, !lang.isEmpty,
           track.language.lowercased() == lang.lowercased() {
            reasons.append("language=\(track.language)")
        }
        switch policy.codecPreference {
        case .compatibility: if track.isAAC  { reasons.append("preferred AAC") }
        case .surround:      if track.isAC3 || track.isEAC3 { reasons.append("preferred surround") }
        case .any:           break
        }
        if policy.respectDefaultFlag && track.isDefault { reasons.append("default-flagged") }
        return reasons.isEmpty ? "first-supported" : reasons.joined(separator: ", ")
    }

    // MARK: - Scoring (private)

    private static func score(_ t: MKVAudioTrackDescriptor,
                               policy: AudioPreferencePolicy) -> Int {
        var s = 0

        // Language match — highest priority (1000 pts)
        if let lang = policy.preferredLanguage, !lang.isEmpty,
           t.language.lowercased() == lang.lowercased() {
            s += 1000
        }

        // Codec preference (up to 100 pts)
        switch policy.codecPreference {
        case .compatibility:
            if      t.isAAC              { s += 100 }
            else if t.isAC3 || t.isEAC3  { s += 50  }
        case .surround:
            if      t.isEAC3             { s += 100 }
            else if t.isAC3              { s += 90  }
            else if t.isAAC              { s += 30  }   // AAC fallback when no surround
        case .any:
            s += 50   // all supported codecs equally weighted
        }

        // Channel count bonus for surround policy (up to 8 pts)
        if policy.codecPreference == .surround { s += min(t.channelCount, 8) }

        // Default-flag tiebreaker (10 pts)
        if policy.respectDefaultFlag && t.isDefault { s += 10 }

        return s
    }
}
