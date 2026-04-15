import SwiftUI

// MARK: - Navigation Tab

enum NavTab: String, CaseIterable, Identifiable {
    case home        = "Home"
    case movies      = "Movies"
    case tvShows     = "TV Shows"
    case collections = "Collections"
    case playlists   = "Playlists"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home:        return "house.fill"
        case .movies:      return "film"
        case .tvShows:     return "tv"
        case .collections: return "rectangle.stack"
        case .playlists:   return "music.note.list"
        }
    }
}

// MARK: - App Destination

enum AppDestination: Equatable {
    case detail(EmbyItem)
    case season(series: EmbyItem, season: EmbyItem)
    case collection(EmbyItem)
    case player(EmbyItem)
    case search
    case settings
}

// MARK: - HomeView

struct HomeView: View {

    @EnvironmentObject var session:  EmbySession
    @EnvironmentObject var settings: AppSettings
    @StateObject private var store   = EmbyLibraryStore()
    @StateObject private var engine  = PlaybackEngine()

    @Namespace private var mainNamespace
    @State private var activeTab:   NavTab          = .home
    @State private var destination: AppDestination? = nil

    var body: some View {
        ZStack {
            switch destination {
            case .detail(let item):
                DetailView(
                    item:           item,
                    session:        session,
                    onPlay:         { play($0) },
                    onRestart:      { restart($0) },
                    onNavigate:     { navigated in withAnimation { destination = .detail(navigated) } },
                    onSelectSeason: { series, season in withAnimation { destination = .season(series: series, season: season) } },
                    onBack:         { withAnimation { destination = nil } }
                )
                .transition(.opacity)

            case .player(let item):
                PlayerContainerView(
                    item:    item,
                    engine:  engine,
                    session: session,
                    onExit:  {
                        engine.stop()
                        withAnimation { destination = nil }
                    }
                )
                .transition(.opacity)

            case .season(let series, let season):
                SeasonDetailView(
                    series:        series,
                    initialSeason: season,
                    session:       session,
                    onSelect:      { episode in withAnimation { destination = .detail(episode) } },
                    onBack:        { withAnimation { destination = nil } }
                )
                .transition(.opacity)

            case .collection(let item):
                CollectionDetailView(
                    collection: item,
                    session:    session,
                    onSelect:   { child in withAnimation { destination = .detail(child) } },
                    onBack:     { withAnimation { destination = nil } }
                )
                .transition(.opacity)

            case .search:
                SearchView(
                    session:   session,
                    onSelect:  { item in withAnimation { destination = .detail(item) } },
                    onDismiss: { withAnimation { destination = nil } }
                )
                .transition(.opacity)

            case .settings:
                SettingsView(
                    availableGenres: store.availableGenres,
                    onDismiss: { withAnimation { destination = nil } }
                )
                .transition(.opacity)

            case nil:
                if settings.scopeUIEnabled {
                    scopeShell.transition(.opacity)
                } else {
                    standardShell.transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: destination)
        .animation(.easeInOut(duration: 0.4),  value: settings.scopeUIEnabled)
        .task {
            guard let server = session.server,
                  let user   = session.user,
                  let token  = session.token else { return }
            await store.load(server: server, userId: user.id, token: token,
                             ribbons: settings.homeRibbons)
        }
        .onChange(of: settings.homeRibbons) { _, newRibbons in
            guard let server = session.server,
                  let user   = session.user,
                  let token  = session.token else { return }
            Task {
                await store.loadRibbons(newRibbons, server: server, userId: user.id, token: token)
            }
        }
    }

    // MARK: - Standard Shell

    private var standardShell: some View {
        ZStack(alignment: .top) {
            CinemaBackground()
            VStack(spacing: 0) {
                standardNavBar.zIndex(10)
                contentArea(scopeMode: false)
            }
        }
    }

    // MARK: - Scope Shell

    private var scopeShell: some View {
        GeometryReader { geo in
            let screen = geo.size
            let canvas = scopeRect(in: screen)

            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                ZStack {
                    // Canvas uses current color mode — bars always black regardless
                    CinemaTheme.backgroundGradient(settings.colorMode)
                    CinemaTheme.radialOverlay(settings.colorMode)
                    CinemaTheme.shimmerOverlay(settings.colorMode)
                }
                .frame(width: canvas.width, height: canvas.height)
                .offset(x: canvas.minX, y: canvas.minY)

                HStack(spacing: 0) {
                    scopeNavRail
                        .focusSection()
                    contentArea(scopeMode: true)
                        .focusSection()
                        .prefersDefaultFocus(true, in: mainNamespace)
                }
                .frame(width: canvas.width, height: canvas.height)
                .offset(x: canvas.minX, y: canvas.minY)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Standard Nav Bar

    private var standardNavBar: some View {
        HStack(spacing: 0) {
            PinneaWordmark(colorMode: settings.colorMode, fontSize: 22)
                .padding(.trailing, 40)

            HStack(spacing: 8) {
                ForEach(NavTab.allCases) { tab in
                    NavTabButton(tab: tab, isActive: activeTab == tab, compact: false) {
                        withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab }
                    }
                }
            }

            Spacer()

            ScopeToggleButton(enabled: $settings.scopeUIEnabled, compact: false)
            NavActionButton(icon: "magnifyingglass", label: "Search", compact: false) { withAnimation { destination = .search } }
            NavActionButton(icon: "gearshape.fill", label: "Settings", compact: false) { withAnimation { destination = .settings } }
            NavActionButton(icon: "rectangle.portrait.and.arrow.right", label: "Sign Out", compact: false) { session.logout() }
                .padding(.leading, 16)
        }
        .padding(.horizontal, CinemaTheme.pagePadding)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial.opacity(settings.colorMode == .light ? 0.85 : 0.5))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CinemaTheme.border(settings.colorMode))
                .frame(height: 1)
        }
    }

    // MARK: - Scope Nav Rail

    private var scopeNavRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            PinneaWordmark(colorMode: settings.colorMode, fontSize: 18)
                .padding(.bottom, 16)

            ForEach(NavTab.allCases) { tab in
                NavTabButton(tab: tab, isActive: activeTab == tab, compact: true) {
                    withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab }
                }
            }

            Spacer()

            ScopeToggleButton(enabled: $settings.scopeUIEnabled, compact: true)
            NavActionButton(icon: "magnifyingglass", label: "Search", compact: true) { withAnimation { destination = .search } }

            NavActionButton(icon: "gearshape.fill", label: "Settings", compact: true) {
                withAnimation { destination = .settings }
            }
            NavActionButton(icon: "rectangle.portrait.and.arrow.right", label: "Sign Out", compact: true) { session.logout() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .frame(width: CinemaTheme.navRailWidth)
        .background(CinemaTheme.surfaceNav(settings.colorMode))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(CinemaTheme.border(settings.colorMode))
                .frame(width: 1)
        }
    }

    // MARK: - Shared buttons



    // MARK: - Content Area

    @ViewBuilder
    private func contentArea(scopeMode: Bool) -> some View {
        switch activeTab {
        case .home:
            homeScreen(scopeMode: scopeMode)
        case .movies:
            SectionGridView(title: "Movies",      items: store.movieItems,  session: session, onSelect: { showDetail($0) })
        case .tvShows:
            SectionGridView(title: "TV Shows",    items: store.showItems,   session: session, onSelect: { showDetail($0) })
        case .collections:
            SectionGridView(title: "Collections", items: store.collections, session: session, onSelect: { showDetail($0) })
        case .playlists:
            SectionGridView(title: "Playlists",   items: store.playlists,   session: session, onSelect: { showDetail($0) })
        }
    }

    // MARK: - Home Screen

    @ViewBuilder
    private func homeScreen(scopeMode: Bool) -> some View {
        if store.isLoading {
            VStack(spacing: 20) {
                Spacer()
                ProgressView().progressViewStyle(.circular).tint(CinemaTheme.accentGold).scaleEffect(1.5)
                Text("Loading library…").font(CinemaTheme.bodyFont).foregroundStyle(CinemaTheme.secondary(settings.colorMode))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let error = store.error {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "exclamationmark.triangle").font(.system(size: 48)).foregroundStyle(.yellow)
                Text(error).foregroundStyle(CinemaTheme.secondary(settings.colorMode)).multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity).padding(60)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: CinemaTheme.rowSpacing) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Good \(timeOfDay), \(session.user?.name ?? "")")
                            .font(.system(size: scopeMode ? 28 : 36, weight: .bold))
                            .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                        Text("What are we watching tonight?")
                            .font(.system(size: scopeMode ? 16 : 20))
                            .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
                    }

                    ForEach(settings.homeRibbons.filter(\.enabled)) { ribbon in
                        if ribbon.type == .recommended {
                            // Personalized recommendations use their own large-card row
                            if !store.recommendationItems.isEmpty {
                                RecommendationRow(
                                    title:     ribbon.type.displayName,
                                    items:     store.recommendationItems,
                                    session:   session,
                                    scopeMode: scopeMode,
                                    colorMode: settings.colorMode,
                                    onSelect:  { showDetail($0) }
                                )
                            }
                        } else {
                            let items = store.ribbonItems[ribbon.type.id] ?? []
                            if !items.isEmpty {
                                MediaRow(
                                    title:     ribbon.type.displayName,
                                    items:     items,
                                    session:   session,
                                    cardSize:  ribbon.type.preferredCardSize,
                                    scopeMode: scopeMode,
                                    onSelect:  { showDetail($0) },
                                    onViewAll: viewAllAction(for: ribbon)
                                )
                            }
                        }
                    }
                }
                // Extra vertical padding so cards don't clip when scaled up
                .padding(.horizontal, scopeMode ? 24 : CinemaTheme.pagePadding)
                .padding(.top, 32)
                .padding(.bottom, 60)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: - Helpers

    private func scopeRect(in size: CGSize) -> CGRect {
        let h = size.width / CinemaTheme.scopeRatio
        let y = (size.height - h) / 2
        return CGRect(x: 0, y: y, width: size.width, height: h)
    }

    private var timeOfDay: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12:  return "morning"
        case 12..<17: return "afternoon"
        default:      return "evening"
        }
    }

    private func showDetail(_ item: EmbyItem) {
        if item.type == "BoxSet" {
            withAnimation { destination = .collection(item) }
        } else {
            withAnimation { destination = .detail(item) }
        }
    }

    private func viewAllAction(for ribbon: HomeRibbon) -> (() -> Void)? {
        switch ribbon.type {
        case .movies, .recentMovies:      return { activeTab = .movies }
        case .tvShows, .recentTV:         return { activeTab = .tvShows }
        case .collections:                return { activeTab = .collections }
        case .playlists:                  return { activeTab = .playlists }
        case .continueWatching:           return nil
        case .recommended:                return nil
        case .genre:                      return nil
        }
    }

    private func play(_ item: EmbyItem, startTicks: Int64? = nil) {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }
        Task {
            do {
                let url = try await EmbyAPI.playbackURL(
                    server: server, userId: user.id, token: token,
                    itemId: item.id, itemName: item.name
                )
                let ticks = startTicks ?? (item.userData?.playbackPositionTicks ?? 0)
                await MainActor.run {
                    engine.setReportingContext(server: server, userId: user.id, token: token, itemId: item.id)
                    // Retry handler: if primary URL fails, force transcode
                    engine.setRetryHandler {
                        print("[HomeView] 🔄 Primary failed — forcing transcode for \(item.name)")
                        guard let tUrl = try? await EmbyAPI.forcedTranscodeURL(
                            server: server, userId: user.id, token: token, itemId: item.id) else { return }
                        await MainActor.run {
                            engine.setReportingContext(server: server, userId: user.id, token: token, itemId: item.id)
                            engine.load(url: tUrl, startTicks: ticks)
                        }
                    }
                    engine.load(url: url, startTicks: ticks)
                    withAnimation { destination = .player(item) }
                }
            } catch { print("[HomeView] Playback error: \(error)") }
        }
    }

    private func restart(_ item: EmbyItem) {
        play(item, startTicks: 0)
    }
}

// MARK: - NavTabButton

struct NavTabButton: View {

    let tab:      NavTab
    let isActive: Bool
    let compact:  Bool
    let onTap:    () -> Void

    @EnvironmentObject var settings: AppSettings
    @FocusState private var isFocused: Bool

    var body: some View {
        let mode = settings.colorMode
        Button { onTap() } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: compact ? 15 : 16,
                                  weight: isActive ? .semibold : .regular))
                Text(tab.rawValue)
                    .font(.system(size: compact ? 16 : 18,
                                  weight: isActive ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
                if compact { Spacer() }
            }
            .foregroundStyle(
                isActive  ? CinemaTheme.navActive(mode) :
                isFocused ? CinemaTheme.primary(mode)   :
                            CinemaTheme.secondary(mode)
            )
            .scaleEffect(isFocused ? 1.04 : 1.0, anchor: .leading)
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical,   compact ? 10 : 12)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isActive  ? CinemaTheme.surfaceNav(mode).opacity(mode == .light ? 1 : 0.8) :
                        isFocused ? CinemaTheme.surfaceRaised(mode)                                 :
                                    Color.clear
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isActive  ? CinemaTheme.navActive(mode).opacity(0.5) :
                                isFocused ? CinemaTheme.border(mode)                  :
                                            Color.clear,
                                lineWidth: isActive ? 1.5 : 1)
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

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

// MARK: - ViewAllCard

struct ViewAllCard: View {
    let cardSize:  CardSize
    let scopeMode: Bool
    let onTap:     () -> Void
    @EnvironmentObject var settings: AppSettings
    @FocusState private var isFocused: Bool

    private var cardWidth: CGFloat {
        switch (cardSize, scopeMode) {
        case (.poster, false): return CinemaTheme.standardCardWidth
        case (.poster, true):  return CinemaTheme.scopeCardWidth
        case (.wide,   false): return 320
        case (.wide,   true):  return 220
        case (.thumb,  false): return 360
        case (.thumb,  true):  return 250
        }
    }
    private var cardHeight: CGFloat {
        switch (cardSize, scopeMode) {
        case (.poster, false): return CinemaTheme.standardCardHeight
        case (.poster, true):  return CinemaTheme.scopeCardHeight
        case (.wide,   false): return 180
        case (.wide,   true):  return 124
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
    }
}

// MARK: - MediaCard

struct MediaCard: View {
    let item:      EmbyItem
    let session:   EmbySession
    let cardSize:  CardSize
    let scopeMode: Bool
    let onTap:     () -> Void

    @EnvironmentObject var settings: AppSettings
    @FocusState private var isFocused: Bool

    private var cardWidth: CGFloat {
        scopeMode
            ? (cardSize == .poster ? CinemaTheme.scopeCardWidth  : 240)
            : (cardSize == .poster ? CinemaTheme.standardCardWidth : 320)
    }

    private var cardHeight: CGFloat {
        switch (cardSize, scopeMode) {
        case (.poster, false): return CinemaTheme.standardCardHeight
        case (.poster, true):  return CinemaTheme.scopeCardHeight
        case (.wide,   false): return 180
        case (.wide,   true):  return 124
        case (.thumb,  false): return 203
        case (.thumb,  true):  return 141
        }
    }

    private var posterURL: URL? {
        guard let server = session.server else { return nil }
        let w = Int(cardWidth * 2)
        if cardSize == .thumb {
            // Prefer Thumb image, fall back to first backdrop, then primary
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

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    // Poster image
                    Group {
                        if let url = posterURL {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: { cardPlaceholder }
                        } else {
                            cardPlaceholder
                        }
                    }
                    .frame(width: cardWidth, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    // Progress bar
                    if let ticks = item.userData?.playbackPositionTicks,
                       let total = item.runTimeTicks, total > 0, ticks > 0 {
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
                .frame(width: cardWidth, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
        .focusRingFree()
        .focused($isFocused)
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

// MARK: - ScopeToggleButton

struct ScopeToggleButton: View {
    @Binding var enabled: Bool
    let compact: Bool
    @EnvironmentObject var settings: AppSettings
    @FocusState private var isFocused: Bool

    var body: some View {
        let mode = settings.colorMode
        Button { enabled.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: enabled ? "rectangle.inset.filled" : "rectangle")
                    .font(.system(size: compact ? 15 : 17, weight: .medium))
                Text("Scope UI")
                    .font(.system(size: compact ? 16 : 17, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
                if compact { Spacer() }
            }
            .foregroundStyle(
                enabled   ? CinemaTheme.navActive(mode) :
                isFocused ? CinemaTheme.primary(mode)   :
                            CinemaTheme.secondary(mode)
            )
            .scaleEffect(isFocused ? 1.04 : 1.0, anchor: .leading)
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical,   compact ? 10 : 12)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        enabled   ? CinemaTheme.surfaceNav(mode) :
                        isFocused ? CinemaTheme.surfaceRaised(mode) :
                                    Color.clear
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                enabled   ? CinemaTheme.navActive(mode).opacity(0.5) :
                                isFocused ? CinemaTheme.border(mode)                  :
                                            Color.clear,
                                lineWidth: enabled ? 1.5 : 1
                            )
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - NavActionButton

struct NavActionButton: View {
    let icon:    String
    let label:   String
    let compact: Bool
    let action:  () -> Void
    @EnvironmentObject var settings: AppSettings
    @FocusState private var isFocused: Bool

    var body: some View {
        let mode = settings.colorMode
        Button { action() } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 15 : 18, weight: .medium))
                Text(label)
                    .font(.system(size: compact ? 16 : 18, weight: .medium))
                    .lineLimit(1)
                if compact { Spacer() }
            }
            .foregroundStyle(isFocused ? CinemaTheme.primary(mode) : CinemaTheme.secondary(mode))
            .scaleEffect(isFocused ? 1.04 : 1.0, anchor: .leading)
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical,   compact ? 10 : 12)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFocused ? CinemaTheme.surfaceRaised(mode) : CinemaTheme.surfaceNav(mode).opacity(0.6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(CinemaTheme.border(mode), lineWidth: 1)
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}
