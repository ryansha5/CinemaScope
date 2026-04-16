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

    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaTheme.sectionSpacing) {
            Text(title)
                .font(scopeMode ? .system(size: 20, weight: .semibold) : CinemaTheme.sectionFont)
                .foregroundStyle(CinemaTheme.secondary(settings.colorMode))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scopeMode ? 20 : CinemaTheme.cardSpacing) {
                    ForEach(items) { item in
                        MediaCard(
                            item:      item,
                            session:   session,
                            cardSize:  cardSize,
                            scopeMode: scopeMode
                        ) { onSelect(item) }
                    }
                    // View All card at end of ribbon
                    if let viewAll = onViewAll {
                        ViewAllCard(cardSize: cardSize, scopeMode: scopeMode, onTap: viewAll)
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 4)
            }
            .scrollClipDisabled()
        }
    }
}
