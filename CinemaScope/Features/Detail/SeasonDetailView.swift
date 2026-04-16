import SwiftUI

struct SeasonDetailView: View {

    let series:     EmbyItem
    let initialSeason: EmbyItem       // which season was tapped to get here
    let session:    EmbySession
    let onSelect:   (EmbyItem) -> Void
    let onBack:     () -> Void

    @EnvironmentObject var settings: AppSettings

    // All seasons for the series — loaded once
    @State private var allSeasons:      [EmbyItem] = []
    // Current season being viewed
    @State private var activeSeason:    EmbyItem?  = nil
    // Episodes for the active season
    @State private var episodes:        [EmbyItem] = []
    @State private var loadingEpisodes  = true
    @State private var error:           String?    = nil

    @Namespace private var seasonNamespace

    var body: some View {
        if settings.scopeUIEnabled { scopeShell } else { standardShell }
    }

    // MARK: - Shells

    private var standardShell: some View {
        ZStack(alignment: .top) {
            CinemaBackground()
            VStack(spacing: 0) {
                header.focusSection()
                Divider().background(CinemaTheme.border(settings.colorMode))
                mainLayout
            }
        }
        .task { await loadAll() }
    }

    private var scopeShell: some View {
        GeometryReader { geo in
            let h = geo.size.width / CinemaTheme.scopeRatio
            let y = (geo.size.height - h) / 2
            let canvas = CGRect(x: 0, y: y, width: geo.size.width, height: h)
            VStack(spacing: 0) {
                Color.black.frame(height: canvas.minY)
                ZStack {
                    CinemaTheme.backgroundGradient(settings.colorMode)
                    CinemaTheme.radialOverlay(settings.colorMode)
                    VStack(spacing: 0) {
                        header.focusSection()
                        Divider().background(CinemaTheme.border(settings.colorMode))
                        mainLayout
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
                Color.black
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .task { await loadAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text(series.name)
                    .font(.system(size: settings.scopeUIEnabled ? 13 : 16, weight: .semibold))
                    .foregroundStyle(CinemaTheme.accentGold.opacity(0.85))
                    .lineLimit(1)
                Text(activeSeason?.name ?? initialSeason.name)
                    .font(settings.scopeUIEnabled ? .system(size: 26, weight: .bold) : CinemaTheme.titleFont)
                    .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                    .lineLimit(1)
                    .animation(.easeInOut(duration: 0.2), value: activeSeason?.id)
                // Show watched progress when episodes are loaded, otherwise fall back to total count
                if !episodes.isEmpty {
                    let watched = episodes.filter { $0.userData?.played == true }.count
                    let total   = episodes.count
                    HStack(spacing: 6) {
                        Text(watched == total ? "All watched" : "\(watched) of \(total) watched")
                            .font(CinemaTheme.captionFont)
                            .foregroundStyle(
                                watched == total
                                    ? CinemaTheme.accentGold.opacity(0.8)
                                    : CinemaTheme.secondary(settings.colorMode)
                            )
                        if watched > 0 && watched < total {
                            // Mini progress bar
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.white.opacity(0.15))
                                        .frame(height: 3)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(CinemaTheme.accentGold.opacity(0.7))
                                        .frame(width: g.size.width * CGFloat(watched) / CGFloat(total), height: 3)
                                }
                            }
                            .frame(width: 60, height: 3)
                        }
                    }
                } else if let count = activeSeason?.childCount ?? initialSeason.childCount, count > 0 {
                    Text("\(count) Episode\(count == 1 ? "" : "s")")
                        .font(CinemaTheme.captionFont)
                        .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
                }
            }
            Spacer()
            BackButton(colorMode: settings.colorMode, scopeMode: settings.scopeUIEnabled, onTap: onBack)
        }
        .padding(.horizontal, settings.scopeUIEnabled ? 24 : CinemaTheme.pagePadding)
        .padding(.vertical, settings.scopeUIEnabled ? 14 : 28)
    }

    // MARK: - Main layout: season rail + episode list

    private var mainLayout: some View {
        HStack(spacing: 0) {
            // Left rail — season picker
            seasonRail
                .focusSection()

            Divider().background(CinemaTheme.border(settings.colorMode))

            // Right — episode list
            episodePanel
                .focusSection()
        }
    }

    // MARK: - Season Rail

    private var seasonRail: some View {
        let scope = settings.scopeUIEnabled
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(allSeasons) { s in
                    SeasonRailButton(
                        season:    s,
                        isActive:  activeSeason?.id == s.id,
                        scopeMode: scope,
                        colorMode: settings.colorMode
                    ) {
                        guard activeSeason?.id != s.id else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { activeSeason = s }
                        Task { await loadEpisodes(for: s) }
                    }
                }
                Spacer()
            }
            .padding(.vertical, scope ? 12 : 20)
            .padding(.horizontal, scope ? 12 : 16)
        }
        .frame(width: scope ? 160 : 220)
        .background(CinemaTheme.peacockDeep.opacity(0.4))
    }

    // MARK: - Next Up

    /// The ID of the episode the user should watch next:
    /// — first in-progress episode, or failing that, first unwatched episode.
    private var nextUpId: String? {
        guard !episodes.isEmpty else { return nil }
        if let ep = episodes.first(where: {
            if case .resume = PlaybackCTA.state(for: $0) { return true }
            return false
        }) { return ep.id }
        return episodes.first(where: { $0.userData?.played != true })?.id
    }

    // MARK: - Episode Panel

    @ViewBuilder
    private var episodePanel: some View {
        if loadingEpisodes {
            VStack {
                Spacer()
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.4)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let error {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.yellow)
                Text(error).foregroundStyle(CinemaTheme.secondary(settings.colorMode))
            }
            .frame(maxWidth: .infinity)
        } else if episodes.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "tv").font(.system(size: 52))
                    .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                Text("No episodes found").font(CinemaTheme.bodyFont)
                    .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    let nextUp = nextUpId
                    ForEach(episodes) { episode in
                        EpisodeRow(
                            episode:   episode,
                            session:   session,
                            colorMode: settings.colorMode,
                            scopeMode: settings.scopeUIEnabled,
                            isNextUp:  episode.id == nextUp
                        ) { onSelect(episode) }

                        if episode.id != episodes.last?.id {
                            Divider()
                                .background(CinemaTheme.border(settings.colorMode))
                                .padding(.horizontal, settings.scopeUIEnabled ? 20 : CinemaTheme.pagePadding)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.bottom, 60)
            }
            .clipped(antialiased: false)
            .id(activeSeason?.id ?? "")   // force ScrollView reset when season changes
        }
    }

    // MARK: - Load

    private func loadAll() async {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }

        // Fetch all seasons for this series
        if let fetched = try? await EmbyAPI.fetchSeasons(
            server: server, userId: user.id, token: token, seriesId: series.id) {
            allSeasons   = fetched
            activeSeason = fetched.first(where: { $0.id == initialSeason.id }) ?? fetched.first
        } else {
            allSeasons   = [initialSeason]
            activeSeason = initialSeason
        }

        // Load episodes for the initial season
        if let active = activeSeason {
            await loadEpisodes(for: active)
        }
    }

    private func loadEpisodes(for season: EmbyItem) async {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }
        loadingEpisodes = true
        error           = nil
        do {
            episodes        = try await EmbyAPI.fetchEpisodes(
                server: server, userId: user.id, token: token,
                seriesId: series.id, seasonId: season.id)
            loadingEpisodes = false
        } catch {
            self.error      = error.localizedDescription
            loadingEpisodes = false
        }
    }
}

// MARK: - SeasonRailButton

struct SeasonRailButton: View {
    let season:    EmbyItem
    let isActive:  Bool
    let scopeMode: Bool
    let colorMode: ColorMode
    let onTap:     () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Active indicator bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(isActive ? CinemaTheme.accentGold : Color.clear)
                    .frame(width: 3, height: scopeMode ? 18 : 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(season.name)
                        .font(.system(
                            size: scopeMode ? 14 : 17,
                            weight: isActive ? .bold : isFocused ? .semibold : .regular
                        ))
                        .foregroundStyle(
                            isActive  ? CinemaTheme.primary(colorMode) :
                            isFocused ? CinemaTheme.primary(colorMode) :
                                        CinemaTheme.secondary(colorMode)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if let count = season.childCount, count > 0 {
                        Text("\(count) ep\(count == 1 ? "" : "s")")
                            .font(.system(size: scopeMode ? 10 : 12))
                            .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, scopeMode ? 8 : 10)
            .background(
                isActive  ? CinemaTheme.peacock.opacity(0.35)  :
                isFocused ? CinemaTheme.surfaceRaised(colorMode) :
                            Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isActive  ? CinemaTheme.accentGold.opacity(0.3) :
                        isFocused ? CinemaTheme.border(colorMode)        :
                                    Color.clear,
                        lineWidth: 1
                    )
            }
            .scaleEffect(isFocused ? 1.02 : 1.0, anchor: .leading)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isFocused)
            .animation(.easeInOut(duration: 0.2), value: isActive)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - EpisodeRow

struct EpisodeRow: View {

    let episode:   EmbyItem
    let session:   EmbySession
    let colorMode: ColorMode
    let scopeMode: Bool
    var isNextUp:  Bool = false
    let onTap:     () -> Void

    @FocusState private var isFocused: Bool

    private var thumbURL: URL? {
        guard let server = session.server,
              let tag    = episode.imageTags?.primary else { return nil }
        return EmbyAPI.primaryImageURL(server: server, itemId: episode.id, tag: tag, width: 480)
    }

    private var progress: Double? {
        guard let ticks = episode.userData?.playbackPositionTicks,
              let total = episode.runTimeTicks,
              total > 0, ticks > 0 else { return nil }
        return min(Double(ticks) / Double(total), 1.0)
    }

    private var isWatched: Bool { episode.userData?.played == true }
    private var thumbWidth:  CGFloat { scopeMode ? 152 : 213 }
    private var thumbHeight: CGFloat { scopeMode ?  86 : 120 }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: scopeMode ? 16 : 24) {
                // Thumbnail
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let url = thumbURL {
                            CachedAsyncImage(url: url) { img in img.resizable().scaledToFill() }
                                placeholder: { thumbPlaceholder }
                        } else { thumbPlaceholder }
                    }
                    .frame(width: thumbWidth, height: thumbHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                isFocused
                                    ? CinemaTheme.focusRimGradient(colorMode)
                                    : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                                lineWidth: isFocused ? 2 : 0
                            )
                    }

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

                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: scopeMode ? 14 : 18))
                            .foregroundStyle(CinemaTheme.accentGold)
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .scaleEffect(isFocused ? 1.03 : 1.0, anchor: .leading)
                .shadow(color: isFocused ? CinemaTheme.focusAccent(colorMode).opacity(0.45) : .clear, radius: 14)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)

                // Metadata
                VStack(alignment: .leading, spacing: scopeMode ? 4 : 7) {
                    HStack(spacing: 10) {
                        if let ep = episode.indexNumber {
                            Text("E\(ep)")
                                .font(.system(size: scopeMode ? 13 : 15, weight: .bold))
                                .foregroundStyle(CinemaTheme.accentGold)
                        }
                        Text(episode.name)
                            .font(.system(size: scopeMode ? 15 : 18, weight: .semibold))
                            .foregroundStyle(CinemaTheme.primary(colorMode))
                            .lineLimit(1)
                        if isNextUp {
                            Text("NEXT UP")
                                .font(.system(size: scopeMode ? 9 : 11, weight: .bold))
                                .foregroundStyle(CinemaTheme.bg(colorMode))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(CinemaTheme.accentGold, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    if let mins = episode.runtimeMinutes {
                        Text(formatRuntime(mins))
                            .font(.system(size: scopeMode ? 11 : 13))
                            .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    }
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: scopeMode ? 12 : 15))
                            .foregroundStyle(CinemaTheme.secondary(colorMode))
                            .lineLimit(scopeMode ? 2 : 3)
                    }
                }

                Spacer()

                if isFocused {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: scopeMode ? 28 : 36))
                        .foregroundStyle(CinemaTheme.accentGold)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .padding(.horizontal, scopeMode ? 20 : CinemaTheme.pagePadding)
            .padding(.vertical, scopeMode ? 10 : 14)
            .background(isFocused ? CinemaTheme.surfaceRaised(colorMode) : Color.clear)
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }

    private var thumbPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(CinemaTheme.cardGradient(colorMode))
            Image(systemName: "tv").font(.system(size: scopeMode ? 18 : 24))
                .foregroundStyle(CinemaTheme.tertiary(colorMode))
        }
    }

    private func formatRuntime(_ minutes: Int) -> String {
        let h = minutes / 60; let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
