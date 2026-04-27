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

// MARK: - PendingLabPlay

/// Sprint 43: Carries everything needed to present PlayerLabHostView AND to fall
/// back to AVPlayer cleanly if PlayerLab cannot play the content.
private struct PendingLabPlay: Identifiable {
    let id      = UUID()
    // Presentation
    let item:    EmbyItem
    let url:     URL
    let ticks:   Int64
    let backdrop: URL?
    // Fallback — the already-resolved PlaybackResult and credentials let
    // launchAVPlayer() skip another round-trip to Emby.
    let result:  PlaybackResult
    let server:  EmbyServer
    let user:    EmbyUser
    let token:   String
}

// MARK: - HomeView

struct HomeView: View {

    @EnvironmentObject var env:      PINEAEnvironment
    @EnvironmentObject var session:  EmbySession
    @EnvironmentObject var settings: AppSettings
    @StateObject private var store   = EmbyLibraryStore()
    @StateObject private var engine  = PlaybackEngine()

    @Namespace private var mainNamespace
    @State private var activeTab:   NavTab          = {
        let raw = UserDefaults.standard.string(forKey: "startupTab") ?? NavTab.home.rawValue
        return NavTab(rawValue: raw) ?? .home
    }()
    @State private var destination:    AppDestination? = nil
    /// Sprint 43: non-nil when a PlayerLab session is being presented.
    @State private var pendingLabPlay: PendingLabPlay? = nil

    // MARK: PINEcue selected item loading state
    /// True while fetching the EmbyItem for the PINEcue-selected movie.
    /// Prevents double-taps and drives the banner's loading indicator.
    @State private var isLoadingSelectedItem: Bool = false

    // MARK: Play in-flight guard
    /// Holds the most recent play() task.
    /// Cancelled before a new play() call starts — prevents concurrent prepares
    /// when the tvOS focus engine fires multiple select events in rapid succession.
    @State private var playTask: Task<Void, Never>? = nil

    // MARK: Standard nav rail collapse state
    /// True when any button inside the standard nav rail has focus — rail expands to show labels.
    @State private var railExpanded:  Bool                  = false
    /// Debounce task for collapsing the rail; cancelled if another button gains focus quickly.
    @State private var railExitTask:  Task<Void, Never>?    = nil

    // MARK: HyperView state
    /// The item currently focused inside a "hyper" ribbon (everything below Recommendations).
    @State private var hyperFocusedItem:   EmbyItem?    = nil
    /// The ribbon that contains the focused item.
    @State private var hyperFocusedRibbon: HomeRibbon?  = nil
    /// Debounce task — cleared if focus moves to another hyper card quickly.
    @State private var hyperExitTask: Task<Void, Never>? = nil
    /// ScrollViewReader target: ID of the anchor view placed after the focused ribbon.
    /// Setting this triggers a scrollTo(.bottom) to push the ribbon into the lower third.
    @State private var hyperScrollTarget: String? = nil

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
                .environmentObject(env)
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
        // Sprint 43: PlayerLab full-screen cover.  onFallback hands off to AVPlayer
        // using the already-resolved PlaybackResult so no second Emby round-trip.
        .fullScreenCover(item: $pendingLabPlay) { pending in
            PlayerLabHostView(
                url:         pending.url,
                startTicks:  pending.ticks,
                itemName:    pending.item.name,
                backdropURL: pending.backdrop,
                onExit: {
                    pendingLabPlay = nil
                },
                onFallback: { reason in
                    // PlayerLab could not play the content.  Dismiss the cover and
                    // hand off to AVPlayer using the Emby-provided result captured in
                    // PendingLabPlay.  This result contains the TranscodingUrl /
                    // DirectStreamUrl from Emby — NOT the raw stream URL that PlayerLab
                    // was using.  AVPlayer can play this without any PlayerLab involvement.
                    //
                    // Note: if mode == .playerLabOnlyDebug we still fall back so the
                    // app doesn't hang, but we log it loudly.
                    print("[Route] PlayerLab fallback — reason='\(reason)' — switching to AVPlayer")
                    if settings.playbackEngineMode == .playerLabOnlyDebug {
                        print("[Route] ⚠️  mode=playerLabOnlyDebug but falling back anyway — AVPlayer takes over")
                    }
                    let cap = pending
                    pendingLabPlay = nil
                    // Brief async hop lets the fullScreenCover begin dismissal before
                    // AVPlayer's destination change is applied.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        launchAVPlayer(
                            item:   cap.item,
                            result: cap.result,
                            ticks:  cap.ticks,
                            server: cap.server,
                            user:   cap.user,
                            token:  cap.token
                        )
                    }
                },
                // Sprint 44 — Auto-play next: resolve the next item in parallel with
                // the 5-second countdown, then dismiss the cover and play it.
                fetchNextCandidate: {
                    guard let nextItem = await AutoPlayNextResolver.resolve(
                        for:    pending.item,
                        server: pending.server,
                        userId: pending.user.id,
                        token:  pending.token
                    ) else { return nil }
                    // Build backdrop URL for the countdown overlay preview
                    let backdropTag = nextItem.backdropImageTags?.first
                    let nextBackdrop: URL? = backdropTag.flatMap {
                        URL(string: "\(pending.server.url)/Items/\(nextItem.id)/Images/Backdrop/0"
                          + "?api_key=\(pending.token)&tag=\($0)")
                    }
                    return AutoPlayCandidate(item: nextItem, backdropURL: nextBackdrop)
                },
                onPlayNext: { nextItem in
                    // Dismiss the current cover, then play the next item.
                    // The 150 ms pause matches the onFallback pattern to let
                    // SwiftUI begin the cover dismissal animation first.
                    pendingLabPlay = nil
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        play(nextItem)
                    }
                }
            )
        }
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
        // MARK: Top Shelf deep link — pinea://detail/{itemId}
        .onOpenURL { url in
            guard
                url.scheme == "pinea",
                url.host   == "detail",
                let itemId  = url.pathComponents.dropFirst().first,
                let server  = session.server,
                let user    = session.user,
                let token   = session.token
            else { return }

            Task {
                guard let item = try? await EmbyAPI.fetchItem(
                    server: server, userId: user.id, token: token, itemId: itemId
                ) else { return }
                await MainActor.run {
                    withAnimation { destination = .detail(item) }
                }
            }
        }
    }

    // MARK: - Standard Shell

    private var standardShell: some View {
        ZStack(alignment: .topLeading) {
            CinemaBackground()
            HStack(spacing: 0) {
                standardNavRail
                    .zIndex(10)
                contentArea(scopeMode: false)
                    .focusSection()
            }
            // HyperView: full-screen backdrop, floats above the nav rail (experimental, opt-in)
            if settings.hyperViewEnabled, let item = hyperFocusedItem, let ribbon = hyperFocusedRibbon {
                HyperBackdropPanel(
                    item:      item,
                    ribbon:    ribbon,
                    session:   session,
                    colorMode: settings.colorMode
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .zIndex(20)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.4), value: hyperFocusedItem?.id)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: hyperFocusedItem == nil)
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
                .clipped()
                .offset(x: canvas.minX, y: canvas.minY)

                // HyperView: full-screen backdrop above nav rail + letterbox (experimental, opt-in)
                if settings.hyperViewEnabled, let item = hyperFocusedItem, let ribbon = hyperFocusedRibbon {
                    HyperBackdropPanel(
                        item:      item,
                        ribbon:    ribbon,
                        session:   session,
                        colorMode: settings.colorMode
                    )
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: canvas.minX, y: canvas.minY)
                    .zIndex(20)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: hyperFocusedItem?.id)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: hyperFocusedItem == nil)
    }

    // MARK: - Standard Nav Rail (collapsing left sidebar)
    //
    // Collapsed (default): icon-only, navRailCollapsedWidth wide. All nav/action
    // buttons are DISABLED so the tvOS focus engine cannot land on them while the
    // user browses content. The ONLY focusable element when collapsed is the
    // pinecone logo button — it serves as the deliberate entry point.
    //
    // Expanded: labels visible, navRailWidth wide, all buttons enabled.
    // Rail expands immediately when any item gains focus; collapses 200 ms after
    // all focus leaves (debounced so moving between rail items never flickers).

    private var standardNavRail: some View {
        VStack(alignment: .leading, spacing: 4) {

            // Logo — decorative only, never focusable
            Image("pinea_pinecone")
                .resizable()
                .scaledToFit()
                .frame(height: railExpanded ? 59 : 36)
                .frame(maxWidth: .infinity, alignment: railExpanded ? .leading : .center)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: railExpanded)

            // All nav buttons — always enabled so focus works reliably.
            // The rail expands when any button gains focus and collapses 200 ms
            // after all focus leaves. The content area's .focusSection() keeps
            // focus naturally in the content while browsing.
            ForEach(NavTab.allCases) { tab in
                NavTabButton(
                    tab:            tab,
                    isActive:       activeTab == tab,
                    compact:        true,
                    showLabel:      railExpanded,
                    onFocusChanged: { handleRailFocus(gained: $0) }
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab }
                }
            }

            Spacer()

            ScopeToggleButton(
                enabled:        $settings.scopeUIEnabled,
                compact:        true,
                showLabel:      railExpanded,
                onFocusChanged: { handleRailFocus(gained: $0) }
            )
            .accessibilityLabel(settings.scopeUIEnabled ? "Disable Scope UI" : "Enable Scope UI")

            NavActionButton(
                icon:           "magnifyingglass",
                label:          "Search",
                compact:        true,
                showLabel:      railExpanded,
                onFocusChanged: { handleRailFocus(gained: $0) }
            ) { withAnimation { destination = .search } }

            NavActionButton(
                icon:           "gearshape.fill",
                label:          "Settings",
                compact:        true,
                showLabel:      railExpanded,
                onFocusChanged: { handleRailFocus(gained: $0) }
            ) { withAnimation { destination = .settings } }

            NavActionButton(
                icon:           "rectangle.portrait.and.arrow.right",
                label:          "Sign Out",
                compact:        true,
                showLabel:      railExpanded,
                onFocusChanged: { handleRailFocus(gained: $0) }
            ) { env.signOut() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 24)
        .frame(width: railExpanded ? CinemaTheme.navRailWidth : CinemaTheme.navRailCollapsedWidth)
        .frame(maxHeight: .infinity)
        .background(CinemaTheme.surfaceNav(settings.colorMode))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(CinemaTheme.border(settings.colorMode))
                .frame(width: 1)
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.75), value: railExpanded)
    }

    /// Expands the standard nav rail on focus gain; collapses it 200 ms after
    /// all focus leaves (debounced so transitions between adjacent buttons don't flicker).
    private func handleRailFocus(gained: Bool) {
        if gained {
            railExitTask?.cancel()
            railExitTask = nil
            // Always set, even if already true — if the collapse animation started
            // before this cancel arrived, this reverses it immediately.
            withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                railExpanded = true
            }
        } else {
            railExitTask?.cancel()
            railExitTask = Task {
                try? await Task.sleep(nanoseconds: 800_000_000) // 800 ms — wide enough to outlast any focus transition between adjacent rail buttons
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                        railExpanded = false
                    }
                }
            }
        }
    }

    // MARK: - Scope Nav Rail

    private var scopeNavRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image("pinea_pinecone")
                .resizable()
                .scaledToFit()
                .frame(height: 59)
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
            NavActionButton(icon: "rectangle.portrait.and.arrow.right", label: "Sign Out", compact: true) { env.signOut() }
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

    /// Ribbon types that are always "pinned" at the top and never enter hyper mode.
    private let pinnedRibbonIDs: Set<String> = [
        RibbonType.continueWatching.id,
        RibbonType.recommended.id,
    ]

    @ViewBuilder
    private func homeScreen(scopeMode: Bool) -> some View {
        if store.isLoading {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: CinemaTheme.rowSpacing) {
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBox(width: 340, height: scopeMode ? 24 : 32, cornerRadius: 6, colorMode: settings.colorMode)
                        SkeletonBox(width: 220, height: scopeMode ? 14 : 18, cornerRadius: 4, colorMode: settings.colorMode)
                    }
                    SkeletonRow(title: "Continue Watching",     cardSize: .wide,  count: 6, scopeMode: scopeMode, colorMode: settings.colorMode)
                    SkeletonRow(title: "Recently Added Movies", cardSize: .poster, count: 8, scopeMode: scopeMode, colorMode: settings.colorMode)
                    SkeletonRow(title: "Up Next",               cardSize: .wide,  count: 6, scopeMode: scopeMode, colorMode: settings.colorMode)
                    SkeletonRow(title: "Recently Added TV",     cardSize: .thumb,  count: 7, scopeMode: scopeMode, colorMode: settings.colorMode)
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
            // ── Normal content ────────────────────────────────────────────────
            // ScrollViewReader lets us push the focused hyper ribbon into the
            // lower third of the screen whenever hyper mode activates.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: CinemaTheme.rowSpacing) {
                        // Greeting — softens out when hyper mode is active
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Good \(timeOfDay), \(session.user?.name ?? "")")
                                .font(.system(size: scopeMode ? 28 : 36, weight: .bold))
                                .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                            Text("What are we watching tonight?")
                                .font(.system(size: scopeMode ? 16 : 20))
                                .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
                        }
                        .opacity(hyperFocusedItem == nil ? 1 : 0)
                        .animation(.easeInOut(duration: 0.3), value: hyperFocusedItem == nil)

                        // PINEcue selected movie — only shown when a backend session exists.
                        // Fades with the greeting in hyper mode; does not affect ribbons.
                        if let summary = env.selectedMovieSummary {
                            PINEcueSessionBanner(
                                summary:   summary,
                                isPlaying: env.isSessionPlaying,
                                isLoading: isLoadingSelectedItem,
                                scopeMode: scopeMode,
                                onTap:     { showSelectedSessionItem() }
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .opacity(hyperFocusedItem == nil ? 1 : 0)
                            .animation(.easeInOut(duration: 0.3), value: hyperFocusedItem == nil)
                        }

                        ForEach(settings.homeRibbons.filter(\.enabled)) { ribbon in
                            let isPinned = pinnedRibbonIDs.contains(ribbon.type.id)

                            if ribbon.type == .recommended {
                                if !store.recommendationItems.isEmpty {
                                    RecommendationRow(
                                        title:     ribbon.type.displayName,
                                        items:     store.recommendationItems,
                                        session:   session,
                                        scopeMode: scopeMode,
                                        colorMode: settings.colorMode,
                                        onSelect:  { showDetail($0) },
                                        onPlay:    { play($0) }
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
                                        onViewAll: viewAllAction(for: ribbon),
                                        onItemFocusChanged: (isPinned || !settings.hyperViewEnabled) ? nil : { item, focused in
                                            handleHyperFocus(item: item, ribbon: ribbon, gained: focused)
                                        }
                                    )
                                    // Scroll anchor: placed immediately after the row.
                                    // scrollTo(.bottom) on this anchor aligns the row's
                                    // bottom edge with the viewport bottom — keeping the
                                    // ribbon in the lower third below the backdrop panel.
                                    if !isPinned {
                                        Color.clear
                                            .frame(height: 0)
                                            .id("hyper_anchor_\(ribbon.id)")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, scopeMode ? 24 : CinemaTheme.pagePadding)
                    .padding(.top, 32)
                    .padding(.bottom, 60)
                }
                .scrollClipDisabled()
                // When hyper mode enters a ribbon, scroll so that ribbon sits
                // in the lower third (below the backdrop panel).
                .onChange(of: hyperScrollTarget) { _, target in
                    guard let target else { return }
                    // Small delay lets tvOS's own focus-scroll settle first,
                    // then our animation re-positions to the bottom.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        withAnimation(.easeInOut(duration: 0.45)) {
                            proxy.scrollTo(target, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    /// Called by every card (and the ViewAllCard) in a hyper ribbon whenever focus changes.
    /// Entering: immediately shows the backdrop for that item.
    /// Leaving:  starts a 600 ms debounce window — if another hyper card
    ///           claims focus before the window expires, the exit is cancelled.
    ///           The longer window means focus crossing the ViewAllCard or briefly
    ///           leaving the row won't flash/collapse the backdrop.
    private func handleHyperFocus(item: EmbyItem, ribbon: HomeRibbon, gained: Bool) {
        if gained {
            hyperExitTask?.cancel()
            hyperExitTask = nil
            let isNewRibbon = hyperFocusedRibbon?.id != ribbon.id
            withAnimation(.easeInOut(duration: 0.35)) {
                hyperFocusedItem   = item
                hyperFocusedRibbon = ribbon
            }
            // Trigger scroll-to-bottom only when entering a different ribbon
            // (moving left/right within the same ribbon keeps position stable).
            if isNewRibbon {
                hyperScrollTarget = "hyper_anchor_\(ribbon.id)"
            }
        } else {
            hyperExitTask?.cancel()
            hyperExitTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000) // 600 ms
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        hyperFocusedItem   = nil
                        hyperFocusedRibbon = nil
                        hyperScrollTarget  = nil
                    }
                }
            }
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

    /// Sprint 6/7: Fetch the full EmbyItem for the PINEcue-selected movie and
    /// route into the normal PINEA detail flow.
    /// Guarded against double-tap and missing credentials.
    /// On fetch failure, clears stale session movie state without breaking the home screen.
    private func showSelectedSessionItem() {
        guard !isLoadingSelectedItem,
              let itemId = env.selectedMovieId,
              let server = session.server,
              let user   = session.user,
              let token  = session.token
        else { return }

        isLoadingSelectedItem = true

        Task {
            if let item = try? await EmbyAPI.fetchItem(
                server: server, userId: user.id, token: token, itemId: itemId
            ) {
                await MainActor.run {
                    isLoadingSelectedItem = false
                    showDetail(item)
                }
            } else {
                // Item unavailable — selection is stale or Emby item was removed.
                // Clear only the movie pointers; leave session + library state intact.
                await MainActor.run {
                    isLoadingSelectedItem = false
                    env.clearStaleSessionMovie()
                }
            }
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

        // Cancel any concurrent play() call before starting this one.
        // The tvOS focus engine can fire multiple select events in < 100ms;
        // without this guard each call races to fetch PlaybackInfo and call
        // controller.prepare(), causing URLSession cancellations and
        // duplicate demuxer scans.
        playTask?.cancel()

        let task = Task {
            do {
                let mode = settings.playbackEngineMode
                print("[Route] Mode=\(mode.rawValue) item='\(item.name)'")

                let result = try await EmbyAPI.playbackURL(
                    server: server, userId: user.id, token: token,
                    itemId: item.id, itemName: item.name
                )

                // Use PlaybackCTA to decide where to resume. If startTicks is
                // explicitly supplied (e.g. restart) that takes precedence;
                // otherwise use the shared CTA logic so threshold rules apply.
                let ticks = startTicks ?? PlaybackCTA.state(for: item).primaryStartTicks

                // ── AVPlayerOnly — skip PlayerLab entirely ────────────────────
                //
                // In this mode we never run PlayerLab route logic, never build raw
                // stream URLs, and never touch PlayerLab state.  AVPlayer receives a
                // fresh PlaybackResult straight from Emby with no PlayerLab involvement.
                if mode == .avPlayerOnly {
                    print("[Route] PlayerLab skipped because mode=AVPlayerOnly")
                    print("[Route] → AVPlayer — url=\(result.url.absoluteString.prefix(80))")
                    await MainActor.run {
                        launchAVPlayer(item: item, result: result,
                                       ticks: ticks, server: server, user: user, token: token)
                    }
                    return
                }

                // ── PlayerLab routing (playerLabPreferred / playerLabOnlyDebug) ──
                //
                // Two-stage evaluation:
                //
                // Stage A — PlayerLab raw stream (metadata-based, ignores playMethod):
                //   For MKV/HEVC/TrueHD/PGS files Emby says "Transcode" because AVPlayer
                //   can't handle them natively. PlayerLab reads the original file via
                //   HTTP byte-range IO and demuxes locally — Emby's transcoding is never
                //   needed. We evaluate compatibility from the MediaSource metadata and,
                //   if compatible, hand PlayerLab the raw static-stream URL.
                //
                // Stage B — Standard route (Emby's DirectPlay, or AVPlayer transcode):
                //   If Stage A doesn't fire (incompatible codec/container, or raw URL
                //   couldn't be built), fall back to the Emby-driven route.
                //   DirectPlay→PlayerLab, DirectStream/Transcode→AVPlayer.

                // Stage A: can PlayerLab play the raw stream?
                let rawRoute = PlaybackRouter.evaluateForPlayerLab(
                    source:           result.selectedSource,
                    playerLabEnabled: true   // already gated by mode != .avPlayerOnly above
                )
                print("[Route] [Raw]      \(rawRoute.logLine)")

                let rawURL: URL? = rawRoute.isPlayerLab
                    ? EmbyAPI.rawStreamURL(
                        server:        server,
                        token:         token,
                        itemId:        item.id,
                        mediaSourceId: result.mediaSourceId,
                        container:     result.selectedSource?.container ?? "")
                    : nil

                // Stage B: standard Emby-driven route (DirectPlay or AVPlayer)
                let standardRoute = PlaybackRouter.decide(
                    source:           result.selectedSource,
                    playMethod:       result.playMethod,
                    url:              result.url,
                    playerLabEnabled: true   // already gated above
                )
                print("[Route] [Standard] \(standardRoute.logLine)")

                // Shared backdrop URL for the PlayerLab loading screen
                let backdropTag = item.backdropImageTags?.first
                let backdropURL: URL? = backdropTag.flatMap {
                    URL(string: "\(server.url)/Items/\(item.id)/Images/Backdrop/0"
                      + "?api_key=\(token)&tag=\($0)")
                }

                // In playerLabOnlyDebug, always route to PlayerLab regardless of
                // confidence.  In playerLabPreferred, use the confidence threshold.
                let confidenceThreshold = (mode == .playerLabOnlyDebug)
                    ? PlaybackConfidence.low     // accept any confidence in debug mode
                    : settings.playerLabMinConfidence

                await MainActor.run {
                    if let rawURL, rawRoute.meetsThreshold(confidenceThreshold) {
                        // ── PlayerLab raw stream (bypasses Emby transcode) ────
                        // `result` is preserved in PendingLabPlay so the onFallback
                        // handler can pass the Emby URL to AVPlayer cleanly if
                        // PlayerLab cannot open the raw stream.
                        print("[Route] → PlayerLab raw stream: \(rawURL.absoluteString.prefix(80))")
                        pendingLabPlay = PendingLabPlay(
                            item:     item,
                            url:      rawURL,
                            ticks:    ticks,
                            backdrop: backdropURL,
                            result:   result,
                            server:   server,
                            user:     user,
                            token:    token
                        )
                    } else if standardRoute.meetsThreshold(confidenceThreshold) {
                        // ── PlayerLab direct-play (Emby says DirectPlay) ──────
                        print("[Route] → PlayerLab direct-play: \(result.url.absoluteString.prefix(80))")
                        pendingLabPlay = PendingLabPlay(
                            item:     item,
                            url:      result.url,
                            ticks:    ticks,
                            backdrop: backdropURL,
                            result:   result,
                            server:   server,
                            user:     user,
                            token:    token
                        )
                    } else {
                        // ── AVPlayer (transcode, unsupported format, below threshold) ──
                        print("[Route] → AVPlayer (PlayerLab confidence below threshold or codec unsupported)")
                        launchAVPlayer(
                            item:   item,
                            result: result,
                            ticks:  ticks,
                            server: server,
                            user:   user,
                            token:  token
                        )
                    }
                }
            } catch { print("[Route] ❌ Playback error: \(error)") }
        }
        playTask = task
    }

    /// Direct AVPlayer-only path — fetches fresh PlaybackInfo and plays without
    /// any PlayerLab involvement.  Use for testing AVPlayer baseline or as a
    /// manual override when PlayerLab is misbehaving.
    ///
    /// Never touches PlayerLab state, pending session, or raw stream URLs.
    func playWithAVPlayerOnly(_ item: EmbyItem, startTicks: Int64? = nil) {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }
        Task {
            do {
                print("[Route] playWithAVPlayerOnly — fetching fresh PlaybackInfo for '\(item.name)'")
                let result = try await EmbyAPI.playbackURL(
                    server: server, userId: user.id, token: token,
                    itemId: item.id, itemName: item.name
                )
                let ticks = startTicks ?? PlaybackCTA.state(for: item).primaryStartTicks
                print("[Route] playWithAVPlayerOnly → AVPlayer url=\(result.url.absoluteString.prefix(80))")
                await MainActor.run {
                    // Ensure any in-flight PlayerLab session is dismissed first.
                    pendingLabPlay = nil
                    launchAVPlayer(item: item, result: result,
                                   ticks: ticks, server: server, user: user, token: token)
                }
            } catch {
                print("[Route] ❌ playWithAVPlayerOnly fetch error: \(error)")
            }
        }
    }

    /// Configures and starts AVPlayer for the given item + already-resolved result.
    ///
    /// Clean-state guarantee: this method is self-contained.  It does not read
    /// PlayerLab state, raw stream URLs, or pending session data.  It receives
    /// only the PlaybackResult from Emby (TranscodingUrl / DirectStreamUrl / url)
    /// and applies it to a freshly-configured PlaybackEngine.
    ///
    /// Called from:
    ///   • play() when mode=avPlayerOnly or confidence below threshold
    ///   • playWithAVPlayerOnly() for explicit testing / override
    ///   • PlayerLabHostView.onFallback when PlayerLab cannot play the content
    private func launchAVPlayer(
        item:   EmbyItem,
        result: PlaybackResult,
        ticks:  Int64,
        server: EmbyServer,
        user:   EmbyUser,
        token:  String
    ) {
        print("[Route] launchAVPlayer — '\(item.name)'  method=\(result.playMethod)  url=\(result.url.absoluteString.prefix(80))")

        // Stop any currently-playing session cleanly before reconfiguring.
        // This clears the progress timer, sends a Stopped report to Emby, and
        // resets the AVPlayer item — preventing state from one session leaking
        // into the next (e.g. after a PlayerLab fallback or retry).
        engine.stop()

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
        engine.setDiagnosticInfo(itemName: item.name, isRetry: false)

        // Populate the available audio track list so the OSD picker has data to show.
        // `selectedSource` carries the MediaStreams from PlaybackInfo; this is nil only
        // on forced-transcode fallback paths, in which case we clear the track list to
        // avoid showing stale data from a previous item.
        if let source = result.selectedSource {
            let tracks = source.audioStreams.compactMap { AvailableAudioTrack.from($0) }
            engine.setAvailableAudioTracks(tracks, selectedIndex: result.selectedAudioStreamIndex)
        } else {
            engine.setAvailableAudioTracks([], selectedIndex: nil)
        }

        // Retry handler: if primary URL fails, request FRESH PlaybackInfo and
        // force H.264 HLS transcode — completely independent of PlayerLab state.
        // Passes the preferred audio stream index from the difficult-file analysis
        // so Emby picks the same compatible track on the retry session.
        let preferredAudioIdx = result.selectedAudioStreamIndex
        engine.setRetryHandler {
            print("[Route] 🔄 AVPlayer primary failed — forcing transcode for '\(item.name)' "
                + "(preferredAudioStreamIndex=\(preferredAudioIdx.map { "\($0)" } ?? "nil"))")
            guard let fallback = try? await EmbyAPI.forcedTranscodeURL(
                server:                    server,
                userId:                    user.id,
                token:                     token,
                itemId:                    item.id,
                preferredAudioStreamIndex: preferredAudioIdx,
                itemName:                  item.name
            ) else {
                print("[Route] ❌ forcedTranscodeURL threw — cannot recover")
                return
            }
            print("[Route] 🔄 Retry URL: \(fallback.url.absoluteString.prefix(80))")
            await MainActor.run {
                engine.setReportingContext(
                    server: server, userId: user.id, token: token, itemId: item.id,
                    mediaSourceId: fallback.mediaSourceId,
                    playSessionId: fallback.playSessionId,
                    playMethod:    fallback.playMethod)
                engine.setDiagnosticInfo(itemName: item.name, isRetry: true)
                engine.load(url: fallback.url, startTicks: ticks)
            }
        }
        engine.load(url: result.url, startTicks: ticks)
        withAnimation { destination = .player(item) }
    }

    private func restart(_ item: EmbyItem) {
        play(item, startTicks: 0)
    }
}
