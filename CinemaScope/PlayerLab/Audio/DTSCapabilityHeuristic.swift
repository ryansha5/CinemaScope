// MARK: - PlayerLab / Audio / DTSCapabilityHeuristic
// Sprint 35 — Lightweight device-aware DTS passthrough capability probe.
//
// Determines at compile time (platform constants) whether DTS hardware
// passthrough is likely available.  The check is intentionally simple.
//
// Failure modes and their consequences:
//   False negative (capable device → returns false):
//     PlayerLab routes to AVPlayer, which handles DTS natively.
//     Audio plays correctly.  Outcome: safe, conservative.
//   False positive (incapable device → returns true):
//     PlayerLab enqueues kAudioFormatDTS buffers; AVSampleBufferAudioRenderer
//     yields silence.  Logged as ⚠️ with no crash.
//     Outcome: silent audio — suboptimal but not a crash.
//
// The asymmetry favors false negatives: a silent-audio outcome (false positive)
// is worse UX than routing to AVPlayer (false negative), so we keep the
// heuristic conservative on all non-tvOS platforms.
//
// NOT production-ready. Debug / lab use only.

import Foundation

enum DTSCapabilityHeuristic {

    // MARK: - Public API

    /// `true` when DTS passthrough via `kAudioFormatDTS` is worth attempting.
    ///
    /// Platform heuristic:
    ///   • tvOS  (Apple TV)  true  — HDMI out is standard; AV receiver likely present.
    ///   • iOS / iPadOS      false — no DTS-capable passthrough in typical consumer use.
    ///   • macOS             false — conservative default; no digital-route check.
    ///
    /// `false` routes DTS-only files to AVPlayer, which handles DTS natively,
    /// so playback still succeeds on non-capable platforms.
    static var isLikelyCapable: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }

    /// Short label for use in log messages and debug UI.
    ///
    /// Examples: "likely capable"  /  "not likely capable"
    static var capabilityLabel: String {
        isLikelyCapable ? "likely capable" : "not likely capable"
    }
}
