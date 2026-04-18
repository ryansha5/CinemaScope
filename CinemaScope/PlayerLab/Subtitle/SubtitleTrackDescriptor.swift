// MARK: - PlayerLab / Subtitle / SubtitleTrackDescriptor
//
// Sprint 26 — Subtitle track metadata model.
// Container-agnostic descriptor for one subtitle track.
//
// Sources:
//   • MKV TrackEntry (trackType == 17)
//   • External .srt file (synthetic descriptor)

import Foundation

struct SubtitleTrackDescriptor: Identifiable {

    /// Stable identity for SwiftUI lists.
    let id: UUID

    /// Container track number.  0 for external / synthetic tracks.
    let trackNumber: UInt64

    /// Container codec ID, e.g. "S_TEXT/UTF8", "tx3g", "external/srt".
    let codecID: String

    /// ISO 639-2 language code.  "und" if not specified by the container.
    let language: String

    /// Optional title / track name from container metadata.
    let title: String

    /// True if the container marks this as the default subtitle track.
    let isDefault: Bool

    /// True if the container marks this as a forced subtitle (e.g. foreign-language lines only).
    let isForced: Bool

    // MARK: - Capabilities

    /// True if this track can be decoded and displayed as plain text.
    var isSRTCompatible: Bool {
        codecID == "S_TEXT/UTF8" || codecID == "external/srt"
    }

    /// True if this is an externally-loaded file (not embedded in the container).
    var isExternal: Bool { codecID.hasPrefix("external/") }

    // MARK: - Display label for HUD / debug menu

    var displayLabel: String {
        var parts = [String]()
        if !language.isEmpty && language != "und" { parts.append(language) }
        if isForced  { parts.append("forced") }
        if isDefault { parts.append("default") }
        let suffix = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        return (title.isEmpty ? codecID : title) + suffix
    }

    // MARK: - Factory

    /// Creates a descriptor for an externally-loaded SRT file.
    static func externalSRT(language: String = "und", title: String = "") -> SubtitleTrackDescriptor {
        SubtitleTrackDescriptor(id: UUID(), trackNumber: 0, codecID: "external/srt",
                                 language: language, title: title,
                                 isDefault: false, isForced: false)
    }
}
