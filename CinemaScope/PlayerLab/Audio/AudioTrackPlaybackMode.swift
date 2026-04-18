// MARK: - PlayerLab / Audio / AudioTrackPlaybackMode
// Sprint 36 — Truthful internal model for audio playback paths.
//
// Solves the "pretend AC3" problem introduced in Sprint 34:
// when a TrueHD track's AC3 core is extracted, the original
// TrackInfo.codecFourCC ("A_TRUEHD") is preserved unchanged.
// AudioFormatFactory reads this type to know which codec path to
// use for actual decoding, independently of the track's label.
//
// This separation means:
//   • Logs can truthfully say "AC3 extracted from TrueHD"
//   • TrackInfo never lies about its origin
//   • The extraction mechanism is explicit, not hidden in metadata
//   • Future TrueHD native support can add a new case without breaking anything
//
// NOT production-ready. Debug / lab use only.

import Foundation

// MARK: - AudioTrackPlaybackMode

enum AudioTrackPlaybackMode {

    /// The track is decoded natively using its own codec.
    ///
    /// AudioFormatFactory dispatches on `audioTrack.codecFourCC` as usual.
    case native

    /// An embedded sub-codec is extracted from the outer format and decoded.
    ///
    /// Example: A_TRUEHD packet stream that embeds AC3 sync frames.
    ///
    /// - sourceCodecID: Container codec identifier (e.g. "A_TRUEHD").
    /// - decodedAs:     Effective codec after extraction (e.g. "ac-3").
    case extractedCore(sourceCodecID: String, decodedAs: String)

    // MARK: - Derived

    /// Codec identifier that AudioFormatFactory should use for dispatch.
    ///
    /// Returns the extracted codec for `.extractedCore`, or `nil` for `.native`
    /// (caller uses `audioTrack.codecFourCC` in that case).
    var effectiveCodecFourCC: String? {
        guard case .extractedCore(_, let dec) = self else { return nil }
        return dec
    }

    /// Human-readable description for logs and debug UI.
    ///
    /// `.native`                              → "native"
    /// `.extractedCore("A_TRUEHD", "ac-3")`  → "AC3 extracted from TrueHD"
    var displayLabel: String {
        switch self {
        case .native:
            return "native"
        case .extractedCore(let src, let dec):
            return "\(Self.friendlyName(dec)) extracted from \(Self.friendlyName(src))"
        }
    }

    // MARK: - Private helpers

    /// Converts a raw codec identifier to a human-readable name.
    private static func friendlyName(_ id: String) -> String {
        switch id {
        case "A_TRUEHD":  return "TrueHD"
        case "A_DTS":     return "DTS-Core"
        case "A_DTS/MA", "A_DTS/LOSSLESS": return "DTS-HD MA"
        case "A_DTS/HRA": return "DTS-HD HRA"
        case "A_DTS/X":   return "DTS:X"
        case "ac-3":      return "AC3"
        case "ec-3":      return "E-AC3"
        case "mp4a":      return "AAC"
        case "dtsc":      return "DTS-Core"
        default:          return id
        }
    }
}
