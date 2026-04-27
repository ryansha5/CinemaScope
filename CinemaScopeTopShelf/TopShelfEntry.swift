import Foundation

// MARK: - TopShelfEntry
//
// Mirror of CinemaScope/Services/TopShelf/TopShelfEntry.swift.
// Keep both copies in sync — they share the same JSON written to the App Group.

struct TopShelfEntry: Codable {
    let itemId:      String
    let title:       String
    let type:        String
    let seriesName:  String?
    let backdropURL: String?
    let thumbURL:    String?
}
