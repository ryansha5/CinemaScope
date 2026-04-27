import Foundation

// MARK: - TopShelfEntry
//
// Lightweight Codable snapshot of a Continue Watching item written to the
// shared App Group by the main app, then read by the Top Shelf extension.
// Keep this struct in sync with the identical copy in CinemaScopeTopShelf/.

struct TopShelfEntry: Codable {
    /// Emby item ID — used as the deep-link payload.
    let itemId:      String
    /// Display title shown under the card.
    let title:       String
    /// "Movie" | "Episode" — used to decide the subtitle format.
    let type:        String
    /// Series name (Episode only) — shown as the primary label.
    let seriesName:  String?
    /// Absolute URL string of the 16:9 backdrop image.
    let backdropURL: String?
    /// Absolute URL string of the 16:9 thumb image (fallback).
    let thumbURL:    String?
}
