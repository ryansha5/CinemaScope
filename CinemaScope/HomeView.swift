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
    case collection(EmbyItem)
    case player(EmbyItem)
    case search
}

// MARK: - Card Size

enum CardSize {
    case poster
    case wide
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
                    item:    item,
                    session: session,
                    onPlay:  { play($0) },
                    onBack:  { withAnimation { destination = nil } }
                )
                .transition(.opacity)

            case .player(let item):
                PlayerContainerView(
                    item:    item,
                    engine:  engine,
                    session: session,
                    onExit:  {
                        engine.pause()
                        withAnimation { destination = nil }
                    }
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
            await store.load(server: server, userId: user.id, token: token)
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
                    CinemaTheme.backgroundGradient
                    CinemaTheme.radialOverlay
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
            Text("CS")
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(CinemaTheme.accentGold)
                .padding(.trailing, 40)

            HStack(spacing: 8) {
                ForEach(NavTab.allCases) { tab in
                    NavTabButton(tab: tab, isActive: activeTab == tab, compact: false) {
                        withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab }
                    }
                }
            }

            Spacer()

            scopeToggleButton(compact: false)
            searchButton(compact: false)

            Button("Sign Out") { session.logout() }
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.3))
                .focusRingFree()
                .padding(.leading, 24)
        }
        .padding(.horizontal, CinemaTheme.pagePadding)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial.opacity(0.5))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CinemaTheme.peacockLight.opacity(0.15))
                .frame(height: 1)
        }
    }

    // MARK: - Scope Nav Rail

    private var scopeNavRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CS")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(CinemaTheme.accentGold)
                .padding(.bottom, 16)

            ForEach(NavTab.allCases) { tab in
                NavTabButton(tab: tab, isActive: activeTab == tab, compact: true) {
                    withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab }
                }
            }

            Spacer()

            scopeToggleButton(compact: true)
            searchButton(compact: true)

            Button {
                session.logout()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 15))
                    Text("Sign Out")
                        .font(.system(size: 16))
                }
                .foregroundStyle(.white.opacity(0.3))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .focusRingFree()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .frame(width: CinemaTheme.navRailWidth)
        .background(CinemaTheme.peacockDeep.opacity(0.5))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(CinemaTheme.peacockLight.opacity(0.15))
                .frame(width: 1)
        }
    }

    // MARK: - Shared buttons

    private func scopeToggleButton(compact: Bool) -> some View {
        Button {
            settings.scopeUIEnabled.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: settings.scopeUIEnabled ? "rectangle.inset.filled" : "rectangle")
                    .font(.system(size: compact ? 15 : 17, weight: .medium))
                Text("Scope UI")
                    .font(.system(size: compact ? 16 : 17, weight: .medium))
            }
            .foregroundStyle(settings.scopeUIEnabled ? CinemaTheme.accentGold : .white.opacity(0.5))
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical,   compact ? 10 : 12)
            .background(
                settings.scopeUIEnabled ? CinemaTheme.peacockDeep.opacity(0.8) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        settings.scopeUIEnabled ? CinemaTheme.accentGold.opacity(0.4) : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .focusRingFree()
    }

    private func searchButton(compact: Bool) -> some View {
        Button {
            withAnimation { destination = .search }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: compact ? 15 : 18, weight: .medium))
                Text("Search")
                    .font(.system(size: compact ? 16 : 18, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical,   compact ? 10 : 12)
            .background(CinemaTheme.peacockDeep.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(CinemaTheme.peacockLight.opacity(0.2), lineWidth: 1)
            }
        }
        .focusRingFree()
        .padding(.leading, compact ? 0 : 16)
    }

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
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.5)
                Text("Loading library…").font(CinemaTheme.bodyFont).foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let error = store.error {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "exclamationmark.triangle").font(.system(size: 48)).foregroundStyle(.yellow)
                Text(error).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity).padding(60)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: CinemaTheme.rowSpacing) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Good \(timeOfDay), \(session.user?.name ?? "")")
                            .font(.system(size: scopeMode ? 28 : 36, weight: .bold))
                            .foregroundStyle(.white)
                        Text("What are we watching tonight?")
                            .font(.system(size: scopeMode ? 16 : 20))
                            .foregroundStyle(CinemaTheme.peacockLight.opacity(0.8))
                    }

                    if !store.continueWatchingItems.isEmpty {
                        MediaRow(title: "Continue Watching",     items: store.continueWatchingItems, session: session, cardSize: .wide,   scopeMode: scopeMode, onSelect: { showDetail($0) })
                    }
                    if !store.recentMovies.isEmpty {
                        MediaRow(title: "Recently Added Movies", items: store.recentMovies,          session: session, cardSize: .poster, scopeMode: scopeMode, onSelect: { showDetail($0) })
                    }
                    if !store.recentShows.isEmpty {
                        MediaRow(title: "Recently Added TV",     items: store.recentShows,           session: session, cardSize: .poster, scopeMode: scopeMode, onSelect: { showDetail($0) })
                    }
                    if !store.homeMovies.isEmpty {
                        MediaRow(title: "Movies",                items: store.homeMovies,            session: session, cardSize: .poster, scopeMode: scopeMode, onSelect: { showDetail($0) })
                    }
                    if !store.homeShows.isEmpty {
                        MediaRow(title: "TV Shows",              items: store.homeShows,             session: session, cardSize: .poster, scopeMode: scopeMode, onSelect: { showDetail($0) })
                    }
                }
                // Extra vertical padding so cards don't clip when scaled up
                .padding(.horizontal, scopeMode ? 24 : CinemaTheme.pagePadding)
                .padding(.top, 32)
                .padding(.bottom, 60)
            }
            // Allow content to overflow scroll view bounds so scaled cards aren't clipped
            .clipped(antialiased: false)
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

    private func play(_ item: EmbyItem) {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }
        Task {
            do {
                let url = try await EmbyAPI.playbackURL(
                    server: server, userId: user.id, token: token, itemId: item.id
                )
                await MainActor.run {
                    engine.load(url: url)
                    withAnimation { destination = .player(item) }
                }
            } catch {
                print("[HomeView] Playback error: \(error)")
            }
        }
    }
}

// MARK: - NavTabButton

struct NavTabButton: View {

    let tab:      NavTab
    let isActive: Bool
    let compact:  Bool
    let onTap:    () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: compact ? 15 : 16,
                                  weight: isActive ? .semibold : .regular))
                Text(tab.rawValue)
                    .font(.system(size: compact ? 16 : 18,
                                  weight: isActive ? .semibold : .regular))
                if compact { Spacer() }
            }
            .foregroundStyle(isActive
                ? CinemaTheme.accentGold
                : .white.opacity(isFocused ? 0.9 : 0.55))
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical,   compact ? 10 : 12)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive
                        ? CinemaTheme.peacockDeep.opacity(0.7)
                        : (isFocused ? CinemaTheme.peacock.opacity(0.3) : Color.clear))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isActive ? CinemaTheme.accentGold.opacity(0.4) : Color.clear,
                                lineWidth: 1)
                    }
            )
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

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaTheme.sectionSpacing) {
            Text(title)
                .font(scopeMode ? .system(size: 20, weight: .semibold) : CinemaTheme.sectionFont)
                .foregroundStyle(.white.opacity(0.8))

            // Vertical padding inside the scroll view gives room for
            // the scale-up glow to breathe without clipping
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
                }
                .padding(.vertical, 20)  // room for glow + scale without clipping
                .padding(.horizontal, 4)
            }
            // CRITICAL: disable clipping so scaled cards aren't cut off
            .clipped(antialiased: false)
        }
    }
}

// MARK: - MediaCard

struct MediaCard: View {
    let item:      EmbyItem
    let session:   EmbySession
    let cardSize:  CardSize
    let scopeMode: Bool
    let onTap:     () -> Void

    @FocusState private var isFocused: Bool

    private var cardWidth: CGFloat {
        scopeMode
            ? (cardSize == .poster ? CinemaTheme.scopeCardWidth  : 240)
            : (cardSize == .poster ? CinemaTheme.standardCardWidth : 320)
    }

    private var cardHeight: CGFloat {
        scopeMode
            ? (cardSize == .poster ? CinemaTheme.scopeCardHeight : 135)
            : (cardSize == .poster ? CinemaTheme.standardCardHeight : 180)
    }

    private var posterURL: URL? {
        guard let server = session.server,
              let tag    = item.imageTags?.primary
        else { return nil }
        return EmbyAPI.primaryImageURL(
            server: server, itemId: item.id, tag: tag,
            width: Int(cardWidth * 2)
        )
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
                // Scale and glow — no card button style, no grey box
                .scaleEffect(isFocused ? 1.06 : 1.0, anchor: .center)
                .shadow(
                    color: isFocused
                        ? CinemaTheme.accentGold.opacity(0.55)
                        : .clear,
                    radius: 20, x: 0, y: 8
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)

                // Title
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: scopeMode ? 13 : 16, weight: .semibold))
                        .foregroundStyle(isFocused ? .white : .white.opacity(0.75))
                        .lineLimit(2)
                    if let year = item.productionYear {
                        Text("\(year)")
                            .font(.system(size: scopeMode ? 11 : 13))
                            .foregroundStyle(CinemaTheme.peacockLight.opacity(0.65))
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
            RoundedRectangle(cornerRadius: 8).fill(CinemaTheme.cardGradient)
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
