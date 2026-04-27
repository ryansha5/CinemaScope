import SwiftUI

// MARK: - MediaRow

struct MediaRow: View {
    let title:     String
    let items:     [EmbyItem]
    let session:   EmbySession
    let cardSize:  CardSize
    let scopeMode: Bool
    let onSelect:  (EmbyItem) -> Void
    var onViewAll: (() -> Void)? = nil

    /// HyperView: called when a card in this row gains or loses focus.
    /// Pass non-nil to opt into hyper-mode tracking.
    var onItemFocusChanged: ((EmbyItem, Bool) -> Void)? = nil

    @EnvironmentObject var settings: AppSettings

    /// Tracks the most-recently focused real card so ViewAllCard can "inherit"
    /// its identity — keeping hyper mode alive instead of blanking the backdrop.
    @State private var lastHyperItem: EmbyItem? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaTheme.sectionSpacing) {
            Text(title)
                .font(scopeMode ? .system(size: 20, weight: .semibold) : CinemaTheme.sectionFont)
                .foregroundStyle(CinemaTheme.secondary(settings.colorMode))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scopeMode ? 20 : CinemaTheme.cardSpacing) {
                    ForEach(items) { item in
                        MediaCard(
                            item:           item,
                            session:        session,
                            cardSize:       cardSize,
                            scopeMode:      scopeMode,
                            onTap:          { onSelect(item) },
                            onFocusChanged: { focusedItem, gained in
                                if gained { lastHyperItem = focusedItem }
                                onItemFocusChanged?(focusedItem, gained)
                            }
                        )
                    }
                    // View All card at end of ribbon.
                    // When it gains focus we forward a "gained" event for the last real
                    // item so the hyper backdrop stays visible rather than flickering out.
                    if let viewAll = onViewAll {
                        ViewAllCard(
                            cardSize: cardSize,
                            scopeMode: scopeMode,
                            onTap: viewAll,
                            onFocusChanged: { gained in
                                // When ViewAllCard gains focus, pretend the last real card
                                // is still focused so hyper mode stays active instead of
                                // starting the exit debounce. When ViewAllCard loses focus,
                                // pass "lost" so the debounce can start normally.
                                guard let proxyItem = lastHyperItem else { return }
                                onItemFocusChanged?(proxyItem, gained)
                            }
                        )
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 4)
            }
            .scrollClipDisabled()
        }
    }
}
