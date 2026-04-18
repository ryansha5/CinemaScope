// MARK: - PlayerLab / Subtitle / SubtitleCue
//
// Sprint 26 — Subtitle cue model.
// Container-agnostic representation of a single subtitle entry with
// start time, end time, and display text.
//
// Sources:
//   • MKV S_TEXT/UTF8 — parsed from cluster blocks + BlockDuration
//   • External .srt   — parsed by SRTParser

import Foundation
import CoreMedia

struct SubtitleCue: Identifiable {

    /// Unique identity for SwiftUI diffing.
    let id: UUID

    /// Presentation start time (inclusive).
    let startTime: CMTime

    /// Presentation end time (exclusive).
    /// Use `.invalid` when unknown; SubtitleController substitutes a 5-second default.
    let endTime: CMTime

    /// Display text.  Basic HTML tags (e.g. `<i>`, `<b>`) are stripped at creation.
    let text: String

    init(startTime: CMTime, endTime: CMTime, rawText: String) {
        self.id        = UUID()
        self.startTime = startTime
        self.endTime   = endTime
        self.text      = SubtitleCue.stripBasicHTML(rawText)
    }

    // MARK: - Helpers

    /// Strips simple HTML tags that are common in SRT/MKV text subtitles.
    private static func stripBasicHTML(_ input: String) -> String {
        var result = input
        // Remove <i>, </i>, <b>, </b>, <u>, </u>, <font …>, </font>
        let patterns = ["<[/]?[ibuIBU]>", "<font[^>]*>", "</font>"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
