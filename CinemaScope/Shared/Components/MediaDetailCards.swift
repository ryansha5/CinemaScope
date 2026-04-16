import SwiftUI

// MARK: - SeasonCard
//
// Portrait poster card for a single season in the Seasons ribbon.
// Extracted from DetailView — no logic changes.

struct SeasonCard: View {
    let season:     EmbyItem
    let session:    EmbySession
    let scopeMode:  Bool
    let colorMode:  ColorMode
    let isSelected: Bool
    let onTap:      () -> Void

    @FocusState private var isFocused: Bool

    private var cardWidth:  CGFloat { scopeMode ? 100 : 140 }
    private var cardHeight: CGFloat { scopeMode ? 150 : 210 }

    private var posterURL: URL? {
        guard let server = session.server,
              let tag    = season.imageTags?.primary else { return nil }
        return EmbyAPI.primaryImageURL(server: server, itemId: season.id, tag: tag, width: Int(cardWidth * 2))
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let url = posterURL {
                        CachedAsyncImage(url: url) { img in img.resizable().scaledToFill() }
                            placeholder: { placeholder }
                    } else { placeholder }
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isFocused || isSelected
                                ? CinemaTheme.focusRimGradient(colorMode)
                                : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                            lineWidth: isFocused ? 2.5 : (isSelected ? 2 : 0)
                        )
                }
                .scaleEffect(isFocused ? 1.05 : 1.0, anchor: .bottom)
                .shadow(
                    color: isFocused ? CinemaTheme.focusAccent(colorMode).opacity(0.5) : .clear,
                    radius: 20, x: 0, y: 10
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.68), value: isFocused)

                VStack(alignment: .leading, spacing: 3) {
                    Text(season.name)
                        .font(.system(size: scopeMode ? 12 : 14, weight: .semibold))
                        .foregroundStyle(isSelected
                            ? CinemaTheme.accentGold
                            : CinemaTheme.primary(colorMode))
                        .lineLimit(1)
                    if let count = season.childCount, count > 0 {
                        Text("\(count) ep\(count == 1 ? "" : "s")")
                            .font(.system(size: scopeMode ? 10 : 12))
                            .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    }
                }
                .frame(width: cardWidth, alignment: .leading)
            }
        }
        .focusRingFree()
        .focused($isFocused)
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(CinemaTheme.cardGradient(colorMode))
            Image(systemName: "tv").font(.system(size: scopeMode ? 20 : 28))
                .foregroundStyle(CinemaTheme.tertiary(colorMode))
        }
    }
}

// MARK: - EpisodeThumbCard
//
// Compact 16:9 card used in the single-season inline ribbon on DetailView.
// Extracted from DetailView — no logic changes.

struct EpisodeThumbCard: View {
    let episode:   EmbyItem
    let session:   EmbySession
    let scopeMode: Bool
    let colorMode: ColorMode
    var isCurrent: Bool = false   // true when this card is the episode currently being viewed
    let onTap:     () -> Void

    @FocusState private var isFocused: Bool

    private var cardWidth:  CGFloat { scopeMode ? 180 : 240 }
    private var cardHeight: CGFloat { scopeMode ? 101 : 135 }

    private var thumbURL: URL? {
        guard let server = session.server else { return nil }
        if let tag = episode.imageTags?.thumb {
            return EmbyAPI.thumbImageURL(server: server, itemId: episode.id, tag: tag, width: Int(cardWidth * 2))
        }
        if let tag = episode.imageTags?.primary {
            return EmbyAPI.primaryImageURL(server: server, itemId: episode.id, tag: tag, width: Int(cardWidth * 2))
        }
        return nil
    }

    private var progress: Double? {
        // Only render the bar when there is meaningful, unfinished progress.
        guard case .resume(let ticks) = PlaybackCTA.state(for: episode),
              let total = episode.runTimeTicks, total > 0 else { return nil }
        return min(Double(ticks) / Double(total), 1.0)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let url = thumbURL {
                            CachedAsyncImage(url: url) { img in img.resizable().scaledToFill() }
                                placeholder: { placeholder }
                        } else { placeholder }
                    }
                    .frame(width: cardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(
                                isCurrent
                                    ? LinearGradient(colors: [CinemaTheme.accentGold, CinemaTheme.accentGold.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    : (isFocused
                                        ? CinemaTheme.focusRimGradient(colorMode)
                                        : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom)),
                                lineWidth: (isCurrent || isFocused) ? 2.5 : 0
                            )
                    }

                    // "NOW PLAYING" pill for the current episode
                    if isCurrent {
                        Text("NOW PLAYING")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(CinemaTheme.accentGold, in: RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }

                    // Progress bar
                    if let p = progress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(0.3)).frame(height: 3)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(CinemaTheme.accentGold)
                                    .frame(width: geo.size.width * p, height: 3)
                            }
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 6).padding(.bottom, 6)
                    }

                    // Watched indicator
                    if episode.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(CinemaTheme.accentGold)
                            .padding(5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .scaleEffect(isFocused ? 1.05 : 1.0, anchor: .bottom)
                .shadow(
                    color: isFocused ? CinemaTheme.focusAccent(colorMode).opacity(0.5) : .clear,
                    radius: 18, x: 0, y: 8
                )
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)

                // Labels
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let ep = episode.indexNumber {
                            Text("E\(ep)")
                                .font(.system(size: scopeMode ? 11 : 13, weight: .bold))
                                .foregroundStyle(CinemaTheme.accentGold)
                        }
                        Text(episode.name)
                            .font(.system(size: scopeMode ? 12 : 14, weight: .semibold))
                            .foregroundStyle(CinemaTheme.primary(colorMode))
                            .lineLimit(1)
                    }
                    if let mins = episode.runtimeMinutes {
                        Text(mins >= 60
                             ? "\(mins/60)h \(mins%60)m"
                             : "\(mins)m")
                            .font(.system(size: scopeMode ? 10 : 12))
                            .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    }
                }
                .frame(width: cardWidth, alignment: .leading)
            }
        }
        .focusRingFree()
        .focused($isFocused)
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(CinemaTheme.cardGradient(colorMode))
            Image(systemName: "tv")
                .font(.system(size: scopeMode ? 20 : 26))
                .foregroundStyle(CinemaTheme.tertiary(colorMode))
        }
    }
}

// MARK: - CollectionItemCard
//
// Portrait poster card for a movie/show in the collection ribbon.
// Extracted from DetailView — no logic changes.

struct CollectionItemCard: View {
    let item:      EmbyItem
    let session:   EmbySession
    let scopeMode: Bool
    let colorMode: ColorMode
    let onTap:     () -> Void
    @FocusState private var isFocused: Bool

    private var cardWidth:  CGFloat { scopeMode ? 110 : 160 }
    private var cardHeight: CGFloat { scopeMode ? 165 : 240 }

    private var posterURL: URL? {
        guard let server = session.server,
              let tag    = item.imageTags?.primary else { return nil }
        return EmbyAPI.primaryImageURL(server: server, itemId: item.id, tag: tag, width: Int(cardWidth * 2))
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let url = posterURL {
                        CachedAsyncImage(url: url) { img in img.resizable().scaledToFill() }
                            placeholder: { RoundedRectangle(cornerRadius: 8).fill(CinemaTheme.cardGradient(colorMode)) }
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(CinemaTheme.cardGradient(colorMode))
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isFocused ? CinemaTheme.focusRimGradient(colorMode)
                                      : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                            lineWidth: isFocused ? 2.5 : 0
                        )
                }
                .scaleEffect(isFocused ? 1.05 : 1.0, anchor: .bottom)
                .shadow(color: isFocused ? CinemaTheme.focusAccent(colorMode).opacity(0.5) : .clear, radius: 20, x: 0, y: 10)
                .animation(.spring(response: 0.28, dampingFraction: 0.68), value: isFocused)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: scopeMode ? 12 : 14, weight: .semibold))
                        .foregroundStyle(CinemaTheme.primary(colorMode))
                        .lineLimit(2)
                    if let year = item.productionYear {
                        Text("\(year)")
                            .font(.system(size: scopeMode ? 10 : 12))
                            .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    }
                }
                .frame(width: cardWidth, alignment: .leading)
            }
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - SeasonPickerPill
//
// A single pill in the More Episodes season picker.
// Owns its own @FocusState so it can apply focus styling without
// the default tvOS white-box highlight that .buttonStyle(.plain) doesn't suppress.
// Extracted from DetailView — no logic changes.

struct SeasonPickerPill: View {
    let season:     EmbyItem
    let isSelected: Bool
    let scopeMode:  Bool
    let colorMode:  ColorMode
    let onTap:      () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onTap) {
            Text(season.name)
                .font(.system(size: scopeMode ? 12 : 14,
                              weight: isSelected ? .semibold : .regular))
                .foregroundStyle(
                    isSelected ? CinemaTheme.bg(colorMode) :
                    isFocused  ? CinemaTheme.primary(colorMode) :
                                 CinemaTheme.secondary(colorMode)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isSelected ? CinemaTheme.accentGold :
                    isFocused  ? CinemaTheme.surfaceRaised(colorMode) :
                                 CinemaTheme.surfaceNav(colorMode),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(CinemaTheme.accentGold.opacity(0.4), lineWidth: 1)
                    }
                }
                .scaleEffect(isFocused ? 1.06 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isFocused)
                .animation(.easeInOut(duration: 0.18), value: isSelected)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}
