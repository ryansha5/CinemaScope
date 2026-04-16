import SwiftUI

struct SectionGridView: View {

    let title:     String
    let items:     [EmbyItem]
    let isLoading: Bool
    let session:   EmbySession
    let onSelect:  (EmbyItem) -> Void

    @EnvironmentObject var settings: AppSettings
    @State private var sortOrder: SearchSort = .az

    // Grid sort options — relevance doesn't apply outside search
    private let sortOptions: [SearchSort] = [.az, .year, .rating, .random]

    private var sortedItems: [EmbyItem] {
        switch sortOrder {
        case .relevance, .az: return items.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .year:           return items.sorted { ($0.productionYear ?? 0) > ($1.productionYear ?? 0) }
        case .rating:         return items.sorted { ($0.communityRating ?? 0) > ($1.communityRating ?? 0) }
        case .random:         return items.shuffled()
        }
    }

    var columns: [GridItem] {
        let count:   Int     = settings.scopeUIEnabled ? 10 : 5
        let spacing: CGFloat = settings.scopeUIEnabled ? 10 : 20
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    var body: some View {
        ZStack {
            if settings.scopeUIEnabled {
                Color.clear
            } else {
                CinemaBackground()
            }

            if isLoading {
                // Show skeleton grid while library loads
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: settings.scopeUIEnabled ? 16 : 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBox(width: 200, height: settings.scopeUIEnabled ? 24 : 34, cornerRadius: 6, colorMode: settings.colorMode)
                                .padding(.top, settings.scopeUIEnabled ? 24 : 60)
                            SkeletonBox(width: 300, height: settings.scopeUIEnabled ? 20 : 26, cornerRadius: 5, colorMode: settings.colorMode)
                        }

                        LazyVGrid(columns: columns, spacing: settings.scopeUIEnabled ? 10 : 28) {
                            ForEach(0..<(settings.scopeUIEnabled ? 30 : 15), id: \.self) { _ in
                                SkeletonGridCard(scopeMode: settings.scopeUIEnabled,
                                                colorMode: settings.colorMode)
                            }
                        }
                        .padding(.bottom, 40)
                    }
                    .padding(.horizontal, settings.scopeUIEnabled ? 20 : CinemaTheme.pagePadding)
                    .padding(.vertical, 12)
                }
                .clipped(antialiased: false)
                .allowsHitTesting(false)
            } else if items.isEmpty {
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
                    VStack(alignment: .leading, spacing: settings.scopeUIEnabled ? 16 : 24) {

                        // Title + sort bar
                        VStack(alignment: .leading, spacing: settings.scopeUIEnabled ? 10 : 16) {
                            Text(title)
                                .font(settings.scopeUIEnabled
                                      ? .system(size: 28, weight: .bold)
                                      : CinemaTheme.titleFont)
                                .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                                .padding(.top, settings.scopeUIEnabled ? 24 : 60)

                            // Sort bar
                            HStack(spacing: 0) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(sortOptions, id: \.rawValue) { s in
                                            SearchPill(
                                                label:     s.displayName,
                                                icon:      s.icon,
                                                isActive:  sortOrder == s,
                                                colorMode: settings.colorMode,
                                                scopeMode: settings.scopeUIEnabled,
                                                small:     true
                                            ) {
                                                if sortOrder == s && s == .random {
                                                    // Re-shuffle on repeat tap
                                                    sortOrder = .relevance // force re-evaluation
                                                    sortOrder = .random
                                                } else {
                                                    sortOrder = s
                                                }
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .scrollClipDisabled()

                                Spacer()

                                Text("\(items.count) title\(items.count == 1 ? "" : "s")")
                                    .font(.system(size: settings.scopeUIEnabled ? 11 : 13))
                                    .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                                    .padding(.leading, 12)
                            }
                        }

                        LazyVGrid(columns: columns,
                                  spacing: settings.scopeUIEnabled ? 10 : 28) {
                            ForEach(sortedItems) { item in
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
                        CachedAsyncImage(url: url) { image in
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
        .accessibilityLabel({
            var parts = [item.name]
            if let year = item.productionYear { parts.append(String(year)) }
            return parts.joined(separator: ", ")
        }())
        .accessibilityHint("Activate to view details")
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
