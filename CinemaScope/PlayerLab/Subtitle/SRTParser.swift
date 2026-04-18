// MARK: - PlayerLab / Subtitle / SRTParser
//
// Sprint 26 — SubRip (.srt) text subtitle parser.
//
// Accepts raw UTF-8 (or Latin-1 fallback) data.
// Handles both \n and \r\n line endings.
// Tolerates minor formatting deviations common in real-world SRT files
// (missing sequence numbers, extra blank lines, BOM).
//
// Output: a sorted array of SubtitleCue objects, ready for SubtitleController.
//
// NOT production-ready. Debug / lab use only.

import Foundation
import CoreMedia

struct SRTParser {

    // MARK: - Public API

    /// Parse `data` as a SubRip file.  Returns empty array on failure.
    static func parse(data: Data) -> [SubtitleCue] {
        // Decode: try UTF-8 first, fall back to Latin-1
        guard var content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { return [] }

        // Strip BOM if present
        if content.hasPrefix("\u{FEFF}") { content = String(content.dropFirst()) }

        // Normalise line endings to \n
        content = content.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r",   with: "\n")

        // Split into blocks separated by blank lines
        let blocks = content.components(separatedBy: "\n\n")
        var cues   = [SubtitleCue]()
        cues.reserveCapacity(blocks.count)

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                             .map { $0.trimmingCharacters(in: .whitespaces) }
                             .filter { !$0.isEmpty }
            guard lines.count >= 2 else { continue }

            // Find the timestamp line (first line containing "-->")
            guard let timeLineIdx = lines.firstIndex(where: { $0.contains("-->") }),
                  timeLineIdx < lines.count - 1
            else { continue }

            let timeLine = lines[timeLineIdx]
            guard let (startTime, endTime) = parseTimeLine(timeLine) else { continue }

            // All lines after the timestamp are the text
            let text = lines[(timeLineIdx + 1)...].joined(separator: "\n")
            guard !text.isEmpty else { continue }

            cues.append(SubtitleCue(startTime: startTime, endTime: endTime, rawText: text))
        }

        return cues.sorted { $0.startTime.seconds < $1.startTime.seconds }
    }

    // MARK: - Private helpers

    /// Parses "HH:MM:SS,mmm --> HH:MM:SS,mmm" (SRT) or "HH:MM:SS.mmm --> HH:MM:SS.mmm" (WebVTT-ish).
    private static func parseTimeLine(_ line: String) -> (CMTime, CMTime)? {
        let arrowRange = line.range(of: "-->")
        guard let arrowRange else { return nil }
        let startStr = String(line[..<arrowRange.lowerBound])
        let endStr   = String(line[arrowRange.upperBound...])
        guard let start = parseTimestamp(startStr.trimmingCharacters(in: .whitespaces)),
              let end   = parseTimestamp(endStr.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (start, end)
    }

    /// Parses "HH:MM:SS,mmm" or "HH:MM:SS.mmm" → CMTime.
    private static func parseTimestamp(_ s: String) -> CMTime? {
        // Normalise comma to dot for milliseconds
        let norm = s.replacingOccurrences(of: ",", with: ".")
        let parts = norm.split(separator: ":")
        guard parts.count == 3,
              let h  = Double(parts[0]),
              let m  = Double(parts[1]),
              let sm = Double(parts[2])
        else { return nil }
        let totalSeconds = h * 3600.0 + m * 60.0 + sm
        return CMTime(seconds: totalSeconds, preferredTimescale: 1000)
    }
}
