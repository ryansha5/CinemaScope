import SwiftUI

// MARK: - DetailView
//
// Orchestrator: owns the layout chrome (backgrounds, scroll containers, safe-area handling)
// and composes the Detail screen from section views.
// All data loading lives in DetailViewModel; all rendering lives in the section files.

struct DetailView: View {

    let item:              EmbyItem
    let session:           EmbySession
    let onPlay:            (EmbyItem) -> Void
    let onRestart:         (EmbyItem) -> Void
    let onNavigate:        (EmbyItem) -> Void
    let onSelectSeason:    (EmbyItem, EmbyItem) -> Void
    let onToggleFavorite:  (EmbyItem) async -> Void
    let onBack:            () -> Void

    @EnvironmentObject var settings: AppSettings
    @StateObject private var vm: DetailViewModel

    init(
        item:             EmbyItem,
        session:          EmbySession,
        onPlay:           @escaping (EmbyItem) -> Void,
        onRestart:        @escaping (EmbyItem) -> Void,
        onNavigate:       @escaping (EmbyItem) -> Void,
        onSelectSeason:   @escaping (EmbyItem, EmbyItem) -> Void,
        onToggleFavorite: @escaping (EmbyItem) async -> Void,
        onBack:           @escaping () -> Void
    ) {
        self.item             = item
        self.session          = session
        self.onPlay           = onPlay
        self.onRestart        = onRestart
        self.onNavigate       = onNavigate
        self.onSelectSeason   = onSelectSeason
        self.onToggleFavorite = onToggleFavorite
        self.onBack           = onBack
        _vm = StateObject(wrappedValue: DetailViewModel(item: item, session: session))
    }

    var body: some View {
        if settings.scopeUIEnabled { scopeLayout } else { standardLayout }
    }

    // MARK: - Standard Layout

    private var standardLayout: some View {
        ZStack(alignment: .top) {
            CinemaTheme.backgroundGradient(settings.colorMode)
                .ignoresSafeArea()
            backdropLayer(scopeMode: false)
                .ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 380)
                    mainContent(scopeMode: false)
                }
            }
            .clipped(antialiased: false)
        }
        .ignoresSafeArea()
        .task { await vm.loadAll() }
    }

    // MARK: - Scope Layout

    private var scopeLayout: some View {
        GeometryReader { geo in
            let canvas = scopeRect(in: geo.size)
            VStack(spacing: 0) {
                Color.black.frame(height: canvas.minY)
                ZStack(alignment: .top) {
                    backdropLayer(scopeMode: true)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: canvas.height * 0.38)
                            mainContent(scopeMode: true)
                            Color.clear.frame(height: 40)
                        }
                    }
                    .clipped(antialiased: false)
                }
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
                Color.black
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .task { await vm.loadAll() }
    }

    // MARK: - Backdrop

    private func backdropLayer(scopeMode: Bool) -> some View {
        let backdropURL: URL? = vm.tmdb?.backdropURL()
            ?? {
                guard let server = session.server else { return nil }
                if vm.displayItem.type == "Episode",
                   let seriesId = vm.displayItem.seriesId {
                    return URL(string: "\(server.url)/Items/\(seriesId)/Images/Backdrop?width=1920")
                }
                guard let tag = vm.displayItem.backdropImageTags?.first else { return nil }
                return URL(string: "\(server.url)/Items/\(vm.displayItem.id)/Images/Backdrop?tag=\(tag)&width=1920")
            }()

        return ZStack {
            CinemaTheme.backgroundGradient(settings.colorMode)
            if let url = backdropURL {
                CachedAsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                        .frame(maxWidth: .infinity, alignment: .top)
                        .clipped()
                } placeholder: { Color.clear }
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear,                                           location: 0.00),
                            .init(color: .clear,                                           location: 0.20),
                            .init(color: CinemaTheme.bg(settings.colorMode).opacity(0.75), location: 0.60),
                            .init(color: CinemaTheme.bg(settings.colorMode),               location: 1.00),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(maxHeight: .infinity)
        .clipped()
    }

    // MARK: - Main content (section orchestrator)

    private func mainContent(scopeMode: Bool) -> some View {
        let pad: CGFloat = scopeMode ? 28 : 80
        return VStack(alignment: .leading, spacing: scopeMode ? 28 : 48) {

            // ── Hero: poster + title + meta + genres + CTA ──
            DetailHeroSection(
                displayItem:      vm.displayItem,
                session:          session,
                mediaInfo:        vm.mediaInfo,
                tmdb:             vm.tmdb,
                nextEpisode:      vm.nextEpisode,
                cta:              vm.cta,
                isFavorited:      $vm.isFavorited,
                hasTrailer:       vm.hasTrailer,
                scopeMode:        scopeMode,
                colorMode:        settings.colorMode,
                onPlay:           onPlay,
                onRestart:        onRestart,
                onToggleFavorite: onToggleFavorite,
                onBack:           onBack
            )
            .padding(.horizontal, pad)

            // ── Overview + crew + studios ──
            DetailOverviewSection(
                displayItem: vm.displayItem,
                tmdb:        vm.tmdb,
                directors:   vm.directors,
                writers:     vm.writers,
                scopeMode:   scopeMode,
                colorMode:   settings.colorMode
            )
            .padding(.horizontal, pad)

            // ── Cast ──
            if let tmdbCast = vm.tmdb?.cast, !tmdbCast.isEmpty {
                DetailCastSection(
                    tmdbCast:   Array(tmdbCast.prefix(20)),
                    embyActors: [],
                    session:    session,
                    scopeMode:  scopeMode,
                    colorMode:  settings.colorMode
                )
                .padding(.leading, pad)
            } else if !vm.actors.isEmpty {
                DetailCastSection(
                    tmdbCast:   [],
                    embyActors: vm.actors,
                    session:    session,
                    scopeMode:  scopeMode,
                    colorMode:  settings.colorMode
                )
                .padding(.leading, pad)
            }

            // ── Seasons / Episodes ──
            let showEpisodes = (vm.displayItem.type == "Series" && !vm.seasons.isEmpty)
                             || (vm.displayItem.type == "Episode" && !vm.collectionItems.isEmpty)
            if showEpisodes {
                DetailEpisodesSection(
                    displayItem:           vm.displayItem,
                    seasons:               vm.seasons,
                    singleSeasonEpisodes:  vm.singleSeasonEpisodes,
                    selectedSeason:        vm.selectedSeason,
                    collectionItems:       vm.collectionItems,
                    episodeSeasons:        vm.episodeSeasons,
                    selectedEpisodeSeason: vm.selectedEpisodeSeason,
                    loadingCollection:     vm.loadingCollection,
                    session:               session,
                    scopeMode:             scopeMode,
                    colorMode:             settings.colorMode,
                    onSeasonTapped: { season in
                        vm.selectedSeason = season
                        onSelectSeason(vm.displayItem, season)
                    },
                    onNavigate:   onNavigate,
                    onLoadEpisodes: { season in await vm.loadEpisodesForSeason(season) }
                )
                .padding(.leading, pad)
            }

            // ── Collection siblings (non-episode items only) ──
            if vm.displayItem.type != "Episode" && !vm.collectionItems.isEmpty {
                DetailCollectionSection(
                    collectionItems:   vm.collectionItems,
                    displayItem:       vm.displayItem,
                    collectionName:    vm.collectionName,
                    loadingCollection: vm.loadingCollection,
                    session:           session,
                    scopeMode:         scopeMode,
                    colorMode:         settings.colorMode,
                    onNavigate:        onNavigate
                )
                .padding(.leading, pad)
            }

            // ── Tech Specs ──
            if let info = vm.mediaInfo {
                DetailTechSection(source: info, scopeMode: scopeMode,
                                  colorMode: settings.colorMode)
                    .padding(.horizontal, pad)
            }

            Color.clear.frame(height: 60)
        }
        .padding(.top, scopeMode ? 16 : 24)
    }

    // MARK: - Helpers

    private func scopeRect(in size: CGSize) -> CGRect {
        let h = size.width / CinemaTheme.scopeRatio
        let y = (size.height - h) / 2
        return CGRect(x: 0, y: y, width: size.width, height: h)
    }
}
