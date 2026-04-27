import SwiftUI

// MARK: - MediaCard

struct MediaCard: View {
    let item:      EmbyItem
    let session:   EmbySession
    let cardSize:  CardSize
    let scopeMode: Bool
    let onTap:     () -> Void

    /// Optional callbacks fired when this card's focus state changes.
    /// Used by HyperView to track which item is currently highlighted.
    var onFocusChanged: ((EmbyItem, Bool) -> Void)? = nil

    @EnvironmentObject var settings: AppSettings
    @FocusState private var isFocused: Bool

    private var cardWidth: CGFloat {
        switch (cardSize, scopeMode) {
        case (.poster, false): return CinemaTheme.standardCardWidth
        case (.poster, true):  return CinemaTheme.scopeCardWidth
        case (.wide,   false): return 416   // +30 % (was 320)
        case (.wide,   true):  return 312   // +30 % (was 240)
        default:               return scopeMode ? 240 : 320
        }
    }

    private var cardHeight: CGFloat {
        switch (cardSize, scopeMode) {
        case (.poster, false): return CinemaTheme.standardCardHeight
        case (.poster, true):  return CinemaTheme.scopeCardHeight
        case (.wide,   false): return 234   // +30 % (was 180)
        case (.wide,   true):  return 161   // +30 % (was 124)
        case (.thumb,  false): return 203
        case (.thumb,  true):  return 141
        }
    }

    private var posterURL: URL? {
        guard let server = session.server else { return nil }
        let w = Int(cardWidth * 2)
        // For any 16:9 card (wide or thumb), prefer landscape images over portrait poster.
        // Priority: Thumb (16:9) → first Backdrop → Primary (portrait, last resort).
        if cardSize != .poster {
            if let tag = item.imageTags?.thumb {
                return EmbyAPI.thumbImageURL(server: server, itemId: item.id, tag: tag, width: w)
            }
            if let tag = item.backdropImageTags?.first {
                return EmbyAPI.backdropImageURL(server: server, itemId: item.id, tag: tag, width: w)
            }
        }
        guard let tag = item.imageTags?.primary else { return nil }
        return EmbyAPI.primaryImageURL(server: server, itemId: item.id, tag: tag, width: w)
    }

    /// "S2 E4 · Episode Title" shown below the card
    private var episodeLabel: String {
        var parts: [String] = []
        if let s = item.parentIndexNumber { parts.append("S\(s)") }
        if let e = item.indexNumber       { parts.append("E\(e)") }
        let code = parts.joined(separator: " ")
        if code.isEmpty { return item.name }
        return "\(code) · \(item.name)"
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    // Poster image
                    Group {
                        if let url = posterURL {
                            CachedAsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: { cardPlaceholder }
                        } else {
                            cardPlaceholder
                        }
                    }
                    .accessibilityHidden(true)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Progress bar — only for items with meaningful, unfinished progress
                    if case .resume(let ticks) = PlaybackCTA.state(for: item),
                       let total = item.runTimeTicks, total > 0 {
                        progressBar(ticks: ticks, total: total)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isFocused
                                ? CinemaTheme.focusRimGradient(settings.colorMode)
                                : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                            lineWidth: isFocused ? 2.5 : 0
                        )
                }
                .scaleEffect(isFocused ? 1.06 : 1.0, anchor: .bottom)
                .shadow(
                    color: isFocused ? CinemaTheme.focusAccent(settings.colorMode).opacity(0.5) : .clear,
                    radius: 24, x: 0, y: 12
                )
                .shadow(
                    color: isFocused ? CinemaTheme.focusGlow(settings.colorMode) : .clear,
                    radius: 12, x: 0, y: 4
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.68), value: isFocused)

                // Title
                VStack(alignment: .leading, spacing: 4) {
                    if item.type == "Episode" {
                        // Series name — primary identifier
                        Text(item.seriesName ?? item.name)
                            .font(.system(size: scopeMode ? 13 : 16, weight: .semibold))
                            .foregroundStyle(isFocused
                                ? CinemaTheme.primary(settings.colorMode)
                                : CinemaTheme.secondary(settings.colorMode))
                            .lineLimit(1)
                        // S##E## · episode title
                        Text(episodeLabel)
                            .font(.system(size: scopeMode ? 11 : 13))
                            .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                            .lineLimit(1)
                    } else {
                        Text(item.name)
                            .font(.system(size: scopeMode ? 13 : 16, weight: .semibold))
                            .foregroundStyle(isFocused
                                ? CinemaTheme.primary(settings.colorMode)
                                : CinemaTheme.secondary(settings.colorMode))
                            .lineLimit(2)
                        if let year = item.productionYear {
                            Text("\(year)")
                                .font(.system(size: scopeMode ? 11 : 13))
                                .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                        }
                    }
                }
                .frame(width: cardWidth, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
        .focusRingFree()
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChanged?(item, focused)
        }
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Activate to view details")
    }

    private var accessibilityDescription: String {
        var parts = [item.name]
        if item.type == "Episode" {
            if let s = item.parentIndexNumber { parts.append("Season \(s)") }
            if let e = item.indexNumber       { parts.append("Episode \(e)") }
        } else if let year = item.productionYear {
            parts.append(String(year))
        }
        return parts.joined(separator: ", ")
    }

    private var cardPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(CinemaTheme.cardGradient(settings.colorMode))
            VStack(spacing: 8) {
                Image(systemName: item.type == "Series" ? "tv" : "film")
                    .font(.system(size: scopeMode ? 22 : 32))
                    .foregroundStyle(CinemaTheme.peacockLight.opacity(0.3))
                Text(item.name)
                    .font(.system(size: scopeMode ? 10 : 12))
                    .foregroundStyle(CinemaTheme.peacockLight.opacity(0.25))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
    }

    private func progressBar(ticks: Int64, total: Int64) -> some View {
        let progress = min(Double(ticks) / Double(total), 1.0)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(0.25)).frame(height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(CinemaTheme.accentGold)
                    .frame(width: geo.size.width * progress, height: 4)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }
}

// MARK: - ViewAllCard

struct ViewAllCard: View {
    let cardSize:  CardSize
    let scopeMode: Bool
    let onTap:     () -> Void
    /// Optional: called with `true` when this card gains focus, `false` when it loses it.
    /// Used by MediaRow to keep hyper mode alive while the user navigates to "View All".
    var onFocusChanged: ((Bool) -> Void)? = nil
    @EnvironmentObject var settings: AppSettings
    @FocusState private var isFocused: Bool

    private var cardWidth: CGFloat {
        switch (cardSize, scopeMode) {
        case (.poster, false): return CinemaTheme.standardCardWidth
        case (.poster, true):  return CinemaTheme.scopeCardWidth
        case (.wide,   false): return 416   // +30 % (was 320)
        case (.wide,   true):  return 286   // +30 % (was 220)
        case (.thumb,  false): return 360
        case (.thumb,  true):  return 250
        }
    }
    private var cardHeight: CGFloat {
        switch (cardSize, scopeMode) {
        case (.poster, false): return CinemaTheme.standardCardHeight
        case (.poster, true):  return CinemaTheme.scopeCardHeight
        case (.wide,   false): return 234   // +30 % (was 180)
        case (.wide,   true):  return 161   // +30 % (was 124)
        case (.thumb,  false): return 203   // 16:9 of 360
        case (.thumb,  true):  return 141   // 16:9 of 250
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            isFocused
                                ? CinemaTheme.peacock.opacity(0.5)
                                : CinemaTheme.peacockDeep.opacity(0.6)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isFocused
                                        ? CinemaTheme.focusRimGradient(settings.colorMode)
                                        : LinearGradient(colors: [CinemaTheme.peacockLight.opacity(0.3)],
                                                         startPoint: .top, endPoint: .bottom),
                                    lineWidth: isFocused ? 2 : 1
                                )
                        }
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.grid.2x2")
                            .font(.system(size: scopeMode ? 22 : 32, weight: .light))
                            .foregroundStyle(isFocused ? CinemaTheme.focusAccent(settings.colorMode) : .white.opacity(0.5))
                        Text("View All")
                            .font(.system(size: scopeMode ? 13 : 16, weight: .semibold))
                            .foregroundStyle(isFocused ? .white : .white.opacity(0.6))
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .scaleEffect(isFocused ? 1.06 : 1.0, anchor: .bottom)
                .shadow(color: isFocused ? CinemaTheme.focusAccent(settings.colorMode).opacity(0.55) : .clear, radius: 20, x: 0, y: 10)
                .animation(.spring(response: 0.28, dampingFraction: 0.68), value: isFocused)

                Text("View All")
                    .font(.system(size: scopeMode ? 13 : 16, weight: .semibold))
                    .foregroundStyle(isFocused ? .white : .white.opacity(0.6))
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
        .focusRingFree()
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChanged?(focused)
        }
    }
}
