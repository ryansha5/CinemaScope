import SwiftUI

struct SectionGridView: View {

    let title:    String
    let items:    [EmbyItem]
    let session:  EmbySession
    let onSelect: (EmbyItem) -> Void

    @EnvironmentObject var settings: AppSettings

    var columns: [GridItem] {
        let count:   Int     = settings.scopeUIEnabled ? 10 : 5
        let spacing: CGFloat = settings.scopeUIEnabled ? 10 : 20
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    var body: some View {
        // No canvas management here — the parent shell already
        // constrains this view to the correct region.
        // Just render content with the right background.
        ZStack {
            if settings.scopeUIEnabled {
                // Already inside the peacock canvas frame from HomeView.
                // Use clear so the parent gradient shows through.
                Color.clear
            } else {
                CinemaBackground()
            }

            if items.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.2))
                    Text("Nothing here yet")
                        .font(CinemaTheme.bodyFont)
                        .foregroundStyle(.white.opacity(0.4))
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: settings.scopeUIEnabled ? 20 : 32) {
                        Text(title)
                            .font(settings.scopeUIEnabled
                                  ? .system(size: 28, weight: .bold)
                                  : CinemaTheme.titleFont)
                            .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                            .padding(.top, settings.scopeUIEnabled ? 24 : 60)

                        LazyVGrid(columns: columns,
                                  spacing: settings.scopeUIEnabled ? 10 : 28) {
                            ForEach(items) { item in
                                GridCard(
                                    item:      item,
                                    session:   session,
                                    scopeMode: settings.scopeUIEnabled
                                ) { onSelect(item) }
                            }
                        }
                        .padding(.bottom, 40)
                    }
                    .padding(.horizontal, settings.scopeUIEnabled ? 20 : CinemaTheme.pagePadding)
                    .padding(.vertical, 12)
                }
                .clipped(antialiased: false)
            }
        }
    }
}

// MARK: - GridCard

struct GridCard: View {

    let item:      EmbyItem
    let session:   EmbySession
    let scopeMode: Bool
    let onTap:     () -> Void

    @EnvironmentObject var settings: AppSettings
    @FocusState private var isFocused: Bool

    private var posterURL: URL? {
        guard let server = session.server,
              let tag    = item.imageTags?.primary
        else { return nil }
        return EmbyAPI.primaryImageURL(
            server: server, itemId: item.id, tag: tag,
            width: scopeMode ? 200 : 300
        )
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: scopeMode ? 6 : 10) {
                ZStack {
                    if let url = posterURL {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            placeholderIcon
                        }
                        .clipShape(RoundedRectangle(cornerRadius: scopeMode ? 6 : 10))
                    } else {
                        placeholderIcon
                    }
                }
                .aspectRatio(2/3, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: scopeMode ? 6 : 10)
                        .strokeBorder(
                            isFocused
                                ? CinemaTheme.focusRimGradient(settings.colorMode)
                                : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                            lineWidth: isFocused ? 2.5 : 0
                        )
                }
                .scaleEffect(isFocused ? 1.05 : 1.0, anchor: .bottom)
                .shadow(
                    color: isFocused ? CinemaTheme.focusAccent(settings.colorMode) : .clear,
                    radius: 24, x: 0, y: 12
                )
                .shadow(
                    color: isFocused ? CinemaTheme.focusGlow(settings.colorMode) : .clear,
                    radius: 10, x: 0, y: 3
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.68), value: isFocused)

                Text(item.name)
                    .font(.system(size: scopeMode ? 10 : 16, weight: .semibold))
                    .foregroundStyle(isFocused
                        ? CinemaTheme.primary(settings.colorMode)
                        : CinemaTheme.secondary(settings.colorMode))
                    .lineLimit(2)
                    .animation(.easeOut(duration: 0.15), value: isFocused)

                if let year = item.productionYear {
                    Text("\(year)")
                        .font(.system(size: scopeMode ? 9 : 13))
                        .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                }
            }
        }
        .focusRingFree()
        .focused($isFocused)
    }

    private var placeholderIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: scopeMode ? 6 : 10)
                .fill(CinemaTheme.cardGradient(settings.colorMode))
            VStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: scopeMode ? 18 : 28))
                    .foregroundStyle(CinemaTheme.peacockLight.opacity(0.4))
                Text(item.name)
                    .font(.system(size: scopeMode ? 9 : 12))
                    .foregroundStyle(CinemaTheme.peacockLight.opacity(0.3))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
        }
    }

    private var iconName: String {
        switch item.type {
        case "Series":   return "tv"
        case "BoxSet":   return "rectangle.stack"
        case "Playlist": return "music.note.list"
        default:         return "film"
        }
    }
}
