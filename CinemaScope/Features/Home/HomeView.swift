import SwiftUI

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
    @State private var activeTab:   NavTab          = {
        let raw = UserDefaults.standard.string(forKey: "startupTab") ?? NavTab.home.rawValue
        return NavTab(rawValue: raw) ?? .home
    }()
    @State private var destination: AppDestination? = nil

    var body: some View {
        ZStack {
            switch destination {
            case .detail(let item):
                DetailView(
                    item:              item,
                    session:           session,
                    onPlay:            { play($0) },
                    onRestart:         { restart($0) },
                    onNavigate:        { navigated in withAnimation { destination = .detail(navigated) } },
                    onSelectSeason:    { series, season in withAnimation { destination = .season(series: series, season: season) } },
                    onToggleFavorite:  { favItem in
                        guard let server = session.server,
                              let user   = session.user,
                              let token  = session.token else { return }
                        await store.toggleFavorite(
                            item: favItem, server: server, userId: user.id, token: token)
                    },
                    onBack:            { withAnimation { destination = nil } }
                )
                .id(item.id)
                .transition(.opacity)

            case .player(let item):
                PlayerContainerView(
                    item:           item,
                    engine:         engine,
                    session:        session,
                    scopeUIEnabled: settings.scopeUIEnabled,
                    autoplay:       settings.autoplayNextEpisode,
                    onExit:  {
                        let finalTicks = Int64(engine.currentTime * 10_000_000)
                        engine.stop()
                        store.updatePlaybackPosition(itemId: item.id, positionTicks: finalTicks)
                        withAnimation { destination = nil }
                    },
                    onRetry:    { play(item) },
                    onPlayNext: item.type == "Episode" ? {
                        // Record position for episode that just finished
                        let finalTicks = Int64(engine.currentTime * 10_000_000)
                        store.updatePlaybackPosition(itemId: item.id, positionTicks: finalTicks)
                        // Fetch next episode from the same season and play it
                        Task {
                            guard let server  = session.server,
                                  let user    = session.user,
                                  let token   = session.token,
                                  let sid     = item.seriesId,
                                  let seasId  = item.seasonId,
                                  let epNum   = item.indexNumber else {
                                await MainActor.run { withAnimation { destination = nil } }
                                return
                            }
                            if let eps = try? await EmbyAPI.fetchEpisodes(
                                server: server, userId: user.id, token: token,
                                seriesId: sid, seasonId: seasId) {
                                let sorted  = eps.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
                                if let next = sorted.first(where: { ($0.indexNumber ?? 0) > epNum }) {
                                    await MainActor.run { play(next) }
                                    return
                                }
                            }
                            // No next episode found — return to home
                            await MainActor.run { withAnimation { destination = nil } }
                        }
                    } : nil
                )
                // Player must cover the entire screen — no overscan insets.
                .ignoresSafeArea()
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
                    genres:    store.availableGenres,
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
                .clipped()   // hard-clip to canvas — prevents home ribbons bleeding into letterbox bars
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
                .accessibilityLabel(settings.scopeUIEnabled ? "Disable Scope UI" : "Enable Scope UI")
                .accessibilityHint("Toggles the ultra-wide cinematic layout")
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

    // MARK: - Content Area

    @ViewBuilder
    private func contentArea(scopeMode: Bool) -> some View {
        switch activeTab {
        case .home:
            homeScreen(scopeMode: scopeMode)
        case .movies:
            SectionGridView(title: "Movies",      items: store.movieItems,  isLoading: store.isLoading, session: session, onSelect: { showDetail($0) })
        case .tvShows:
            SectionGridView(title: "TV Shows",    items: store.showItems,   isLoading: store.isLoading, session: session, onSelect: { showDetail($0) })
        case .collections:
            SectionGridView(title: "Collections", items: store.collections, isLoading: store.isLoading, session: session, onSelect: { showDetail($0) })
        case .playlists:
            SectionGridView(title: "Playlists",   items: store.playlists,   isLoading: store.isLoading, session: session, onSelect: { showDetail($0) })
        }
    }

    // MARK: - Home Screen

    @ViewBuilder
    private func homeScreen(scopeMode: Bool) -> some View {
        if store.isLoading {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: CinemaTheme.rowSpacing) {
                    // Greeting skeleton
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBox(width: 340, height: scopeMode ? 24 : 32, cornerRadius: 6, colorMode: settings.colorMode)
                        SkeletonBox(width: 220, height: scopeMode ? 14 : 18, cornerRadius: 4, colorMode: settings.colorMode)
                    }
                    // Skeleton ribbons for default row labels
                    SkeletonRow(title: "Continue Watching",    cardSize: .wide,   count: 6, scopeMode: scopeMode, colorMode: settings.colorMode)
                    SkeletonRow(title: "Recently Added Movies",cardSize: .poster,  count: 8, scopeMode: scopeMode, colorMode: settings.colorMode)
                    SkeletonRow(title: "Up Next",              cardSize: .wide,   count: 6, scopeMode: scopeMode, colorMode: settings.colorMode)
                    SkeletonRow(title: "Recently Added TV",    cardSize: .thumb,  count: 7, scopeMode: scopeMode, colorMode: settings.colorMode)
                }
                .padding(.horizontal, scopeMode ? 24 : CinemaTheme.pagePadding)
                .padding(.top, 32)
                .padding(.bottom, 60)
            }
            .scrollClipDisabled()
            .allowsHitTesting(false)
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
        case .nextUp:                     return nil
        case .recommended:                return nil
        case .favorites:                  return nil
        case .genre:                      return nil
        }
    }

    private func play(_ item: EmbyItem, startTicks: Int64? = nil) {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }
        Task {
            do {
                let result = try await EmbyAPI.playbackURL(
                    server: server, userId: user.id, token: token,
                    itemId: item.id, itemName: item.name
                )
                // Use PlaybackCTA to decide where to resume. If startTicks is
                // explicitly supplied (e.g. restart) that takes precedence;
                // otherwise use the shared CTA logic so threshold rules apply.
                let ticks = startTicks ?? PlaybackCTA.state(for: item).primaryStartTicks
                await MainActor.run {
                    // Tell the engine about the UI mode and item identity BEFORE load.
                    // This sets the correct default viewport and restores any stored AR override.
                    engine.setPlaybackContext(
                        scopeUIEnabled: settings.scopeUIEnabled,
                        serverURL:      server.url,
                        itemId:         item.id
                    )
                    engine.setReportingContext(
                        server: server, userId: user.id, token: token, itemId: item.id,
                        mediaSourceId: result.mediaSourceId,
                        playSessionId: result.playSessionId,
                        playMethod:    result.playMethod)
                    // Retry handler: if primary URL fails, force HLS transcode
                    engine.setRetryHandler {
                        print("[HomeView] 🔄 Primary failed — forcing transcode for \(item.name)")
                        guard let fallback = try? await EmbyAPI.forcedTranscodeURL(
                            server: server, userId: user.id, token: token, itemId: item.id) else { return }
                        await MainActor.run {
                            engine.setReportingContext(
                                server: server, userId: user.id, token: token, itemId: item.id,
                                mediaSourceId: fallback.mediaSourceId,
                                playSessionId: fallback.playSessionId,
                                playMethod:    fallback.playMethod)
                            engine.load(url: fallback.url, startTicks: ticks)
                        }
                    }
                    engine.load(url: result.url, startTicks: ticks)
                    withAnimation { destination = .player(item) }
                }
            } catch { print("[HomeView] Playback error: \(error)") }
        }
    }

    private func restart(_ item: EmbyItem) {
        play(item, startTicks: 0)
    }
}
