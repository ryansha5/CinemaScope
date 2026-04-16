import SwiftUI

// MARK: - DetailCollectionSection
//
// "Also in this collection" ribbon for movies and TV shows that belong to a BoxSet.
// Separates Movies and TV Shows into sub-ribbons when both types are present.
// Extracted from DetailView (PASS 3). No logic changes.

struct DetailCollectionSection: View {
    let collectionItems:   [EmbyItem]
    let displayItem:       EmbyItem
    let collectionName:    String?
    let loadingCollection: Bool
    let session:           EmbySession
    let scopeMode:         Bool
    let colorMode:         ColorMode
    let onNavigate:        (EmbyItem) -> Void

    var body: some View {
        let others   = collectionItems.filter { $0.id != displayItem.id }
        let movies   = others.filter { $0.type == "Movie"  }
        let tvShows  = others.filter { $0.type == "Series" }
        // Items that are neither Movie nor Series (rare) fall into whichever bucket is bigger
        let overflow = others.filter { $0.type != "Movie" && $0.type != "Series" }
        let hasBoth  = !movies.isEmpty && !tvShows.isEmpty

        let heading  = collectionName.map { "Also in the \($0)" } ?? "Also in this collection"

        return VStack(alignment: .leading, spacing: hasBoth ? 24 : 14) {
            Text(heading)
                .font(.system(size: scopeMode ? 18 : 22, weight: .semibold))
                .foregroundStyle(CinemaTheme.primary(colorMode))

            // ── Movies ribbon ──
            if !movies.isEmpty {
                ribbon(
                    items:    movies + (hasBoth ? [] : overflow),
                    sublabel: hasBoth ? "Movies" : nil
                )
            }

            // ── TV Shows ribbon ──
            if !tvShows.isEmpty {
                ribbon(
                    items:    tvShows + (hasBoth ? overflow : []),
                    sublabel: hasBoth ? "TV Shows" : nil
                )
            }

            // Edge case: collection contains only non-Movie/Series items
            if movies.isEmpty && tvShows.isEmpty && !overflow.isEmpty {
                ribbon(items: overflow, sublabel: nil)
            }
        }
        .opacity(loadingCollection ? 0 : 1)
        .animation(.easeIn(duration: 0.3), value: loadingCollection)
    }

    // MARK: - Ribbon helper

    private func ribbon(items: [EmbyItem], sublabel: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sublabel {
                Text(sublabel)
                    .font(.system(size: scopeMode ? 13 : 15, weight: .semibold))
                    .foregroundStyle(CinemaTheme.secondary(colorMode))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scopeMode ? 16 : 24) {
                    ForEach(items) { item in
                        CollectionItemCard(item: item, session: session,
                                          scopeMode: scopeMode, colorMode: colorMode) {
                            onNavigate(item)
                        }
                    }
                }
                .padding(.vertical, 24)
                .padding(.trailing, scopeMode ? 28 : 80)
            }
            .scrollClipDisabled()
        }
    }
}
