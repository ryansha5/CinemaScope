import Foundation

// MARK: - TopShelfStore
//
// Writes/reads Continue Watching snapshots to the shared App Group container
// so the TV Top Shelf Extension can display them without launching the app.
//
// App Group ID must match the entitlement in both targets:
//   group.com.pinea.cinemascope

enum TopShelfStore {

    static let appGroupID = "group.com.pinea.cinemascope"
    static let entriesKey = "topshelf.continueWatching"

    // MARK: - Write (main app)

    /// Called after the Continue Watching ribbon loads.
    /// Builds image URLs, encodes to JSON, and writes to the shared container.
    static func write(items: [EmbyItem], serverURL: String, token: String) {
        let entries: [TopShelfEntry] = items.prefix(10).compactMap { item in
            // Prefer 16:9 thumb, then backdrop, skip if neither exists
            let thumbURL: String? = item.imageTags?.thumb.map { tag in
                "\(serverURL)/Items/\(item.id)/Images/Thumb?api_key=\(token)&tag=\(tag)&MaxWidth=640"
            }
            let backdropURL: String? = item.backdropImageTags?.first.map { tag in
                "\(serverURL)/Items/\(item.id)/Images/Backdrop/0?api_key=\(token)&tag=\(tag)&MaxWidth=640"
            }
            guard thumbURL != nil || backdropURL != nil else { return nil }

            return TopShelfEntry(
                itemId:     item.id,
                title:      item.name,
                type:       item.type,
                seriesName: item.seriesName,
                backdropURL: backdropURL,
                thumbURL:   thumbURL
            )
        }

        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults(suiteName: appGroupID)?.set(data, forKey: entriesKey)
    }

    // MARK: - Read (extension or app)

    static func read() -> [TopShelfEntry] {
        guard
            let data = UserDefaults(suiteName: appGroupID)?.data(forKey: entriesKey),
            let entries = try? JSONDecoder().decode([TopShelfEntry].self, from: data)
        else { return [] }
        return entries
    }
}
