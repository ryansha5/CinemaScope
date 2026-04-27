import Foundation
import TVServices

// MARK: - TopShelfProvider
//
// TV Top Shelf Extension — displays Continue Watching items as a row of
// 16:9 thumbnail cards when the user hovers over the Pinea app icon on the
// Apple TV home screen.  Tapping a card deep-links into the app and opens
// that item's detail page (via the pinea://detail/{itemId} URL scheme).

final class TopShelfProvider: NSObject, TVTopShelfContentProvider {

    private let appGroupID = "group.com.pinea.cinemascope"
    private let entriesKey = "topshelf.continueWatching"

    // MARK: - TVTopShelfContentProvider

    func topShelfItems(completionHandler: @escaping (TVTopShelfContent) -> Void) {
        let entries = loadEntries()

        guard !entries.isEmpty else {
            // Nothing to show — fall back to the static top shelf image.
            completionHandler(TVTopShelfInsetContent(items: []))
            return
        }

        let items: [TVTopShelfItem] = entries.compactMap { entry in
            let item = TVTopShelfItem(identifier: entry.itemId)

            // Title: series name for episodes, movie title otherwise
            item.title = entry.seriesName ?? entry.title

            // 16:9 card shape
            item.imageShape = .hdtv

            // Prefer backdrop; fall back to thumb
            let imageURLStr = entry.backdropURL ?? entry.thumbURL
            if let str = imageURLStr, let url = URL(string: str) {
                item.setImageURL(url, for: .screenScale1x)
                item.setImageURL(url, for: .screenScale2x)
            }

            // Deep link: tapping opens the app and navigates to the detail page
            let deepLink = URL(string: "pinea://detail/\(entry.itemId)")
            item.displayURL = deepLink
            item.playURL    = deepLink

            return item
        }

        let collection = TVTopShelfItemCollection(items: items)
        collection.title = "Continue Watching"

        let content = TVTopShelfSectionedContent(sections: [collection])
        completionHandler(content)
    }

    // MARK: - Private

    private func loadEntries() -> [TopShelfEntry] {
        guard
            let data    = UserDefaults(suiteName: appGroupID)?.data(forKey: entriesKey),
            let entries = try? JSONDecoder().decode([TopShelfEntry].self, from: data)
        else { return [] }
        return entries
    }
}
