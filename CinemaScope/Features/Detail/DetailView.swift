import SwiftUI

struct DetailView: View {

    let item:           EmbyItem
    let session:        EmbySession
    let onPlay:         (EmbyItem) -> Void
    let onRestart:      (EmbyItem) -> Void
    let onNavigate:     (EmbyItem) -> Void     // navigate to another item's detail
    let onSelectSeason: (EmbyItem, EmbyItem) -> Void  // (series, season)
    let onBack:         () -> Void

    @EnvironmentObject var settings: AppSettings
    @State private var detail:            EmbyItem?   = nil
    @State private var tmdb:              TMDBMetadata? = nil
    @State private var mediaInfo:          EmbyMediaSource? = nil
    @State private var collectionItems:      [EmbyItem]  = []
    @State private var seasons:              [EmbyItem]  = []
    @State private var singleSeasonEpisodes: [EmbyItem]  = []   // populated when series has exactly 1 season
    @State private var loadingCollection                 = false
    @State private var selectedSeason:       EmbyItem?   = nil
    // Episode detail — all seasons for the series (drives the season picker in More Episodes)
    @State private var episodeSeasons:       [EmbyItem]  = []
    @State private var selectedEpisodeSeason: EmbyItem?  = nil
    // Collection detail — name of the parent BoxSet (e.g. "Marvel Cinematic Universe")
    @State private var collectionName:       String?     = nil

    enum DetailFocus { case play, restart, trailer }
    @FocusState private var focusedButton: DetailFocus?

    private var displayItem: EmbyItem { detail ?? item }
    /// Single source of truth for the Play / Resume / Restart decision.
    private var cta: PlaybackCTA { PlaybackCTA.state(for: displayItem) }

    /// Next episode to watch for Series items.
    /// Uses singleSeasonEpisodes (populated for single-season shows).
    /// Returns the first in-progress episode, or the first unwatched one.
    private var nextEpisode: EmbyItem? {
        guard displayItem.type == "Series" else { return nil }
        guard !singleSeasonEpisodes.isEmpty else { return nil }
        if let inProgress = singleSeasonEpisodes.first(where: {
            if case .resume = PlaybackCTA.state(for: $0) { return true }
            return false
        }) { return inProgress }
        return singleSeasonEpisodes.first(where: { $0.userData?.played != true })
    }

    private var actors: [EmbyPerson] {
        (displayItem.people ?? []).filter { $0.type == "Actor" }
    }
    private var directors: [EmbyPerson] {
        (displayItem.people ?? []).filter { $0.type == "Director" }
    }
    private var writers: [EmbyPerson] {
        (displayItem.people ?? []).filter { $0.type == "Writer" }
    }
    private var hasTrailer: Bool { tmdb?.trailer != nil }

    var body: some View {
        if settings.scopeUIEnabled { scopeLayout } else { standardLayout }
    }

    // MARK: - Standard Layout

    private var standardLayout: some View {
        ZStack(alignment: .top) {
            // Theme background fills the entire screen first
            CinemaTheme.backgroundGradient(settings.colorMode)
                .ignoresSafeArea()

            // Backdrop image sits on top, fades to transparent at the bottom
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
        .task { await loadAll() }
    }

    // MARK: - Scope Layout

    private var scopeLayout: some View {
        GeometryReader { geo in
            let canvas = scopeRect(in: geo.size)

            // VStack stacks: top black bar / canvas / bottom black bar
            // This is the only reliable way to get equal bars on both sides —
            // offset and padding both have layout side-effects on tvOS.
            VStack(spacing: 0) {
                // Top black bar — exact height of the letterbox bar
                Color.black
                    .frame(height: canvas.minY)

                // Canvas — backdrop + scrollable content, hard-clipped
                ZStack(alignment: .top) {
                    backdropLayer(scopeMode: true)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            // Push content down so it starts in the fade zone
                            // of the backdrop, matching the normal UI composition
                            Color.clear.frame(height: canvas.height * 0.38)
                            mainContent(scopeMode: true)
                            // Bottom padding so last item isn't flush with canvas edge
                            Color.clear.frame(height: 40)
                        }
                    }
                    .clipped(antialiased: false)
                }
                .frame(width: canvas.width, height: canvas.height)
                .clipped()

                // Bottom black bar — fills remaining space
                Color.black
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .task { await loadAll() }
    }

    // MARK: - Backdrop
    // scopeMode = constrained to canvas height; standard = tall hero

    private func backdropLayer(scopeMode: Bool) -> some View {
        // Prefer TMDB's 1280px backdrop; fall back to Emby's
        let backdropURL: URL? = tmdb?.backdropURL()
            ?? {
                guard let server = session.server,
                      let tag = displayItem.backdropImageTags?.first
                else { return nil }
                return URL(string: "\(server.url)/Items/\(displayItem.id)/Images/Backdrop?tag=\(tag)&width=1920")
            }()

        return ZStack {
            CinemaTheme.backgroundGradient(settings.colorMode)
            if let url = backdropURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        // Anchor to top so the subject of the backdrop
                        // is visible — not cropped off at the top
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
        // Scope: fill most of the canvas (~75%). Standard: fills screen height.
        // Canvas is screen_width/2.39 ≈ 803pt on Apple TV 4K
        // Fill full canvas height in scope — the gradient overlay handles the fade
        // Standard: fills screen height
        .frame(height: scopeMode ? nil : nil)
        .frame(maxHeight: .infinity)
        .clipped()
    }

    // MARK: - Main scrollable content

    private func mainContent(scopeMode: Bool) -> some View {
        let pad: CGFloat = scopeMode ? 28 : 80
        return VStack(alignment: .leading, spacing: scopeMode ? 28 : 48) {

            // ── Hero row: poster + title/meta/buttons ──
            heroRow(scopeMode: scopeMode)
                .padding(.horizontal, pad)

            // ── Overview ──
            if let overview = displayItem.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: scopeMode ? 15 : 19))
                    .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
                    .lineLimit(scopeMode ? 4 : 6)
                    .frame(maxWidth: scopeMode ? 560 : 860, alignment: .leading)
                    .padding(.horizontal, pad)
            }

            // ── Crew line — prefer TMDB ──
            crewSection(scopeMode: scopeMode)
                .padding(.horizontal, pad)

            // ── Studios ──
            if let studios = displayItem.studios, !studios.isEmpty {
                studioLine(studios, scopeMode: scopeMode)
                    .padding(.horizontal, pad)
            }

            // ── Cast — prefer TMDB (has profile photos + character names) ──
            if let tmdbCast = tmdb?.cast, !tmdbCast.isEmpty {
                tmdbCastSection(cast: Array(tmdbCast.prefix(20)), scopeMode: scopeMode)
                    .padding(.leading, pad)
            } else if !actors.isEmpty {
                castSection(scopeMode: scopeMode)
                    .padding(.leading, pad)
            }

            // ── Seasons / Episodes (Series only) ──
            if displayItem.type == "Series" && !seasons.isEmpty {
                if seasons.count == 1 && !singleSeasonEpisodes.isEmpty {
                    // Mini-series or single-season — skip season picker, show episodes directly
                    singleSeasonRibbon(scopeMode: scopeMode)
                        .padding(.leading, pad)
                } else if seasons.count > 1 {
                    seasonSection(scopeMode: scopeMode)
                        .padding(.leading, pad)
                }
            }

            // ── More Episodes (if this is an episode, show siblings from same season) ──
            if displayItem.type == "Episode" && !collectionItems.isEmpty {
                moreEpisodesSection(scopeMode: scopeMode)
                    .padding(.leading, pad)
            // ── Collection siblings (movies/shows) ──
            } else if displayItem.type != "Episode" && !collectionItems.isEmpty {
                collectionSection(scopeMode: scopeMode)
                    .padding(.leading, pad)
            }

            // ── Tech Specs ──
            techSpecsIfAvailable(scopeMode: scopeMode)
                .padding(.horizontal, pad)

            Color.clear.frame(height: 60)
        }
        .padding(.top, scopeMode ? 16 : 24)
    }

    // MARK: - Hero Row

    private func heroRow(scopeMode: Bool) -> some View {
        HStack(alignment: .bottom, spacing: scopeMode ? 24 : 48) {
            posterView(scopeMode: scopeMode)

            VStack(alignment: .leading, spacing: scopeMode ? 10 : 16) {
                // Title + tagline
                VStack(alignment: .leading, spacing: 4) {
                    // For episodes, show series name as a breadcrumb above the title
                    if displayItem.type == "Episode", let seriesName = displayItem.seriesName {
                        Text(seriesName)
                            .font(.system(size: scopeMode ? 13 : 17, weight: .semibold))
                            .foregroundStyle(CinemaTheme.accentGold.opacity(0.85))
                            .lineLimit(1)
                    }
                    // Season + episode number line (e.g. "Season 2  ·  Episode 4")
                    if displayItem.type == "Episode" {
                        let parts: [String] = [
                            displayItem.seasonName,
                            displayItem.indexNumber.map { "Episode \($0)" }
                        ].compactMap { $0 }
                        if !parts.isEmpty {
                            Text(parts.joined(separator: "  ·  "))
                                .font(.system(size: scopeMode ? 12 : 15, weight: .medium))
                                .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                                .lineLimit(1)
                        }
                    }
                    Text(displayItem.name)
                        .font(.system(size: scopeMode ? 28 : 46, weight: .bold))
                        .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                        .lineLimit(2)
                    if let tagline = displayItem.taglines?.first, !tagline.isEmpty {
                        Text(tagline)
                            .font(.system(size: scopeMode ? 14 : 18))
                            .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                            .italic().lineLimit(1)
                    }
                }

                // Badges
                metaBadgeRow(scopeMode: scopeMode)

                // Genres — prefer TMDB's, fall back to Emby's
                genrePillsSection(scopeMode: scopeMode)

                // Buttons
                actionButtons(scopeMode: scopeMode)
            }

            Spacer()
        }
    }

    // MARK: - Poster

    private func posterView(scopeMode: Bool) -> some View {
        let w: CGFloat = scopeMode ? 110 : 190
        let h: CGFloat = scopeMode ? 165 : 285
        return Group {
            if let server = session.server,
               let tag = displayItem.imageTags?.primary,
               let url = EmbyAPI.primaryImageURL(server: server, itemId: displayItem.id, tag: tag, width: Int(w * 2)) {
                AsyncImage(url: url) { img in img.resizable().scaledToFill() }
                    placeholder: { RoundedRectangle(cornerRadius: 10).fill(CinemaTheme.cardGradient(settings.colorMode)) }
            } else {
                RoundedRectangle(cornerRadius: 10).fill(CinemaTheme.cardGradient(settings.colorMode))
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.55), radius: 28, x: 0, y: 14)
    }

    // MARK: - Meta badges

    private func metaBadgeRow(scopeMode: Bool) -> some View {
        HStack(spacing: 8) {
            if let year = displayItem.productionYear { badge("\(year)") }
            if let r = displayItem.officialRating    { badge(r) }
            // Runtime for movies/episodes
            if let m = displayItem.runtimeMinutes, displayItem.type != "Series" {
                badge(formatRuntime(m))
            }
            if let s = displayItem.communityRating   { badge(String(format: "★ %.1f", s), gold: true) }
            // Type badge
            switch displayItem.type {
            case "Series":
                badge("Series")
                if let c = displayItem.childCount, c > 0  { badge("\(c) Season\(c == 1 ? "" : "s")") }
                if let e = displayItem.episodeCount, e > 0 { badge("\(e) Episodes") }
            case "Episode":
                badge("Episode")
                if let sn = displayItem.seasonName  { badge(sn) }
                if let ep = displayItem.indexNumber { badge("Ep \(ep)") }
            default:
                badge("Movie")
            }
            // Technical quality badges — resolution and HDR from loaded media info
            if let video = mediaInfo?.videoStream {
                if let res = video.resolutionLabel { badge(res) }
                if let hdr = video.hdrLabel        { badge(hdr, gold: true) }
            }
        }
    }

    private func badge(_ text: String, gold: Bool = false) -> some View {
        Text(text)
            .font(CinemaTheme.captionFont)
            .foregroundStyle(gold ? CinemaTheme.accentGold : CinemaTheme.secondary(settings.colorMode))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                gold ? CinemaTheme.accentGold.opacity(0.15) : CinemaTheme.surfaceNav(settings.colorMode),
                in: RoundedRectangle(cornerRadius: 6)
            )
    }

    // MARK: - Genre pills

    private func genrePills(_ genres: [String], scopeMode: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(genres.prefix(5), id: \.self) { g in
                Text(g)
                    .font(.system(size: scopeMode ? 12 : 14, weight: .medium))
                    .foregroundStyle(CinemaTheme.accentGold.opacity(0.9))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(CinemaTheme.accentGold.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(CinemaTheme.accentGold.opacity(0.25), lineWidth: 1) }
            }
        }
    }

    // MARK: - TMDB Cast section

    private func tmdbCastSection(cast: [TMDBCastMember], scopeMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cast")
                .font(.system(size: scopeMode ? 18 : 22, weight: .semibold))
                .foregroundStyle(CinemaTheme.primary(settings.colorMode))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scopeMode ? 16 : 24) {
                    ForEach(cast) { member in
                        TMDBCastCard(member: member, scopeMode: scopeMode,
                                     colorMode: settings.colorMode)
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, scopeMode ? 28 : 80)
            }
            .clipped(antialiased: false)
        }
    }

    // MARK: - Crew line

    private func crewLine(scopeMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !directors.isEmpty {
                crewEntry(label: "Director", names: directors.prefix(2).map(\.name))
            }
            if !writers.isEmpty {
                crewEntry(label: "Writer", names: writers.prefix(2).map(\.name))
            }
        }
    }

    private func crewEntry(label: String, names: [String]) -> some View {
        HStack(spacing: 8) {
            Text(label + ":")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
            Text(names.joined(separator: ", "))
                .font(.system(size: 15))
                .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
        }
    }

    // MARK: - Studios

    private func studioLine(_ studios: [EmbyStudio], scopeMode: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Studio:")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
            Text(studios.prefix(2).map(\.name).joined(separator: ", "))
                .font(.system(size: 15))
                .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
        }
    }

    // MARK: - Cast section

    private func castSection(scopeMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cast")
                .font(.system(size: scopeMode ? 18 : 22, weight: .semibold))
                .foregroundStyle(CinemaTheme.primary(settings.colorMode))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scopeMode ? 16 : 24) {
                    ForEach(actors.prefix(20)) { person in
                        CastCard(person: person, session: session,
                                 scopeMode: scopeMode, colorMode: settings.colorMode)
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, scopeMode ? 28 : 80)
            }
            .clipped(antialiased: false)
        }
    }

    // MARK: - Collection section

    // MARK: - Single season episode ribbon

    private func singleSeasonRibbon(scopeMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Episodes")
                .font(.system(size: scopeMode ? 18 : 22, weight: .semibold))
                .foregroundStyle(CinemaTheme.primary(settings.colorMode))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scopeMode ? 14 : 20) {
                    ForEach(singleSeasonEpisodes) { episode in
                        EpisodeThumbCard(
                            episode:   episode,
                            session:   session,
                            scopeMode: scopeMode,
                            colorMode: settings.colorMode,
                            isCurrent: false
                        ) { onSelectSeason(displayItem, seasons[0]) }
                        // Tapping goes to SeasonDetailView so user can
                        // navigate episodes with the full player context
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, scopeMode ? 28 : 80)
            }
            .clipped(antialiased: false)
        }
    }

    // MARK: - Seasons section

    private func seasonSection(scopeMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Seasons")
                .font(.system(size: scopeMode ? 18 : 22, weight: .semibold))
                .foregroundStyle(CinemaTheme.primary(settings.colorMode))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scopeMode ? 16 : 24) {
                    ForEach(seasons) { season in
                        SeasonCard(
                            season:    season,
                            session:   session,
                            scopeMode: scopeMode,
                            colorMode: settings.colorMode,
                            isSelected: selectedSeason?.id == season.id
                        ) {
                            selectedSeason = season
                            onSelectSeason(displayItem, season)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, scopeMode ? 28 : 80)
            }
            .clipped(antialiased: false)
        }
    }

    // MARK: - More episodes section (for episode detail pages)

    private func moreEpisodesSection(scopeMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {

            // ── Header row: title + season picker ──
            HStack(alignment: .center, spacing: 16) {
                Text("More Episodes")
                    .font(.system(size: scopeMode ? 18 : 22, weight: .semibold))
                    .foregroundStyle(CinemaTheme.primary(settings.colorMode))

                // Season picker — only shown when there are multiple seasons
                if episodeSeasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(episodeSeasons) { season in
                                SeasonPickerPill(
                                    season:     season,
                                    isSelected: selectedEpisodeSeason?.id == season.id,
                                    scopeMode:  scopeMode,
                                    colorMode:  settings.colorMode
                                ) {
                                    guard selectedEpisodeSeason?.id != season.id else { return }
                                    Task { await loadEpisodesForSeason(season) }
                                }
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }

            // ── Episode thumb ribbon ──
            // ScrollViewReader lets us jump to the current episode (or ep 1
            // when the user switches to a different season).
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: scopeMode ? 16 : 24) {
                        ForEach(collectionItems.filter { $0.type == "Episode" }) { ep in
                            EpisodeThumbCard(
                                episode:   ep,
                                session:   session,
                                scopeMode: scopeMode,
                                colorMode: settings.colorMode,
                                isCurrent: ep.id == displayItem.id
                            ) { onNavigate(ep) }
                            .id(ep.id)   // anchor for scrollTo
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.trailing, scopeMode ? 28 : 80)
                }
                .clipped(antialiased: false)
                // Helper — works for both onAppear and onChange
                .onAppear {
                    scrollToTarget(in: collectionItems, proxy: proxy)
                }
                // Season switch: collectionItems changes while the view is live
                .onChange(of: collectionItems) { episodes in
                    scrollToTarget(in: episodes, proxy: proxy)
                }
            }
        }
        .opacity(loadingCollection ? 0 : 1)
        .animation(.easeIn(duration: 0.25), value: loadingCollection)
    }

    private func collectionSection(scopeMode: Bool) -> some View {
        let others   = collectionItems.filter { $0.id != displayItem.id }
        let movies   = others.filter { $0.type == "Movie"  }
        let tvShows  = others.filter { $0.type == "Series" }
        // Items that are neither Movie nor Series (rare) fall into whichever bucket is bigger
        let overflow = others.filter { $0.type != "Movie" && $0.type != "Series" }
        let hasBoth  = !movies.isEmpty && !tvShows.isEmpty

        let heading  = collectionName.map { "Also in the \($0)" } ?? "Also in this collection"

        return VStack(alignment: .leading, spacing: hasBoth ? 24 : 14) {
            Text(heading)
                .font(.system(size: scopeMode ? 18 : 22, weight: .semibold))
                .foregroundStyle(CinemaTheme.primary(settings.colorMode))

            // ── Movies ribbon ──
            if !movies.isEmpty {
                collectionRibbon(
                    items:     movies + (hasBoth ? [] : overflow),
                    sublabel:  hasBoth ? "Movies" : nil,
                    scopeMode: scopeMode
                )
            }

            // ── TV Shows ribbon ──
            if !tvShows.isEmpty {
                collectionRibbon(
                    items:     tvShows + (hasBoth ? overflow : []),
                    sublabel:  hasBoth ? "TV Shows" : nil,
                    scopeMode: scopeMode
                )
            }

            // Edge case: collection contains only non-Movie/Series items
            if movies.isEmpty && tvShows.isEmpty && !overflow.isEmpty {
                collectionRibbon(items: overflow, sublabel: nil, scopeMode: scopeMode)
            }
        }
        .opacity(loadingCollection ? 0 : 1)
        .animation(.easeIn(duration: 0.3), value: loadingCollection)
    }

    private func collectionRibbon(items: [EmbyItem], sublabel: String?, scopeMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sublabel {
                Text(sublabel)
                    .font(.system(size: scopeMode ? 13 : 15, weight: .semibold))
                    .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scopeMode ? 16 : 24) {
                    ForEach(items) { item in
                        CollectionItemCard(item: item, session: session,
                                          scopeMode: scopeMode, colorMode: settings.colorMode) {
                            onNavigate(item)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, scopeMode ? 28 : 80)
            }
            .clipped(antialiased: false)
        }
    }

    // MARK: - Action buttons

    private func actionButtons(scopeMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {

                // ── Series: primary CTA is "Continue" / "Play" for the next episode ──
                if displayItem.type == "Series", let next = nextEpisode {
                    let nextCTA   = PlaybackCTA.state(for: next)
                    let playLabel = nextCTA.showsRestart ? "Continue" : "Play"
                    DetailActionButton(icon: "play.fill", label: playLabel,
                        style: .primary, scopeMode: scopeMode, isFocused: focusedButton == .play,
                        colorMode: settings.colorMode) { onPlay(next) }
                    .focused($focusedButton, equals: .play)

                } else {
                    // ── Movie / Episode: standard Play / Resume ──
                    DetailActionButton(icon: "play.fill", label: cta.showsRestart ? "Resume" : "Play",
                        style: .primary, scopeMode: scopeMode, isFocused: focusedButton == .play,
                        colorMode: settings.colorMode) { onPlay(displayItem) }
                    .focused($focusedButton, equals: .play)

                    if cta.showsRestart {
                        DetailActionButton(icon: "arrow.counterclockwise", label: "Restart",
                            style: .secondary, scopeMode: scopeMode, isFocused: focusedButton == .restart,
                            colorMode: settings.colorMode) { onRestart(displayItem) }
                        .focused($focusedButton, equals: .restart)
                    }
                }

                if hasTrailer, let trailer = tmdb?.trailer {
                    DetailActionButton(icon: "play.rectangle", label: "Trailer",
                        style: .secondary, scopeMode: scopeMode, isFocused: focusedButton == .trailer,
                        colorMode: settings.colorMode) { openTrailer(trailer) }
                    .focused($focusedButton, equals: .trailer)
                }

                BackButton(colorMode: settings.colorMode, scopeMode: scopeMode, onTap: onBack)
            }
            .onAppear { focusedButton = .play }

            // ── Next episode context line for Series ──
            if displayItem.type == "Series", let next = nextEpisode {
                let s  = next.parentIndexNumber.map { "S\($0)" } ?? ""
                let e  = next.indexNumber.map      { "E\($0)" } ?? ""
                let se = [s, e].filter { !$0.isEmpty }.joined(separator: "·")
                Text("\(se.isEmpty ? "" : "\(se)  —  ")\(next.name)")
                    .font(.system(size: scopeMode ? 12 : 14))
                    .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                    .lineLimit(1)
            }

            // ── Resume position hint for movies / episodes ──
            if displayItem.type != "Series", let label = cta.resumeLabel {
                Text(label)
                    .font(.system(size: scopeMode ? 12 : 14))
                    .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
            }
        }
    }

    // MARK: - Safe genre pills (no let-in-ViewBuilder)

    @ViewBuilder
    private func genrePillsSection(scopeMode: Bool) -> some View {
        let genres: [String] = {
            if let g = tmdb?.genres, !g.isEmpty { return g }
            return displayItem.genres ?? []
        }()
        if !genres.isEmpty {
            genrePills(genres, scopeMode: scopeMode)
        }
    }

    // MARK: - Safe crew section (no let-in-ViewBuilder)

    @ViewBuilder
    private func crewSection(scopeMode: Bool) -> some View {
        let tmdbDirs    = tmdb?.directors ?? []
        let tmdbWrts    = tmdb?.writers   ?? []
        if !tmdbDirs.isEmpty || !tmdbWrts.isEmpty {
            tmdbCrewLine(directors: tmdbDirs, writers: tmdbWrts, scopeMode: scopeMode)
        } else if !directors.isEmpty || !writers.isEmpty {
            crewLine(scopeMode: scopeMode)
        }
    }

    // MARK: - TMDB crew line

    private func tmdbCrewLine(directors: [TMDBCrewMember], writers: [TMDBCrewMember], scopeMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !directors.isEmpty {
                crewEntry(label: "Director", names: directors.prefix(2).map(\.name))
            }
            if !writers.isEmpty {
                crewEntry(label: "Writer", names: writers.prefix(2).map(\.name))
            }
        }
    }

    private func openTrailer(_ trailer: TMDBVideo) {
        let appURL = URL(string: "youtube://\(trailer.key)")
        let webURL = URL(string: "https://www.youtube.com/watch?v=\(trailer.key)")
        if let appURL, UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else if let webURL {
            UIApplication.shared.open(webURL)
        }
    }

    // MARK: - Tech Specs

    @ViewBuilder
    private func techSpecsIfAvailable(scopeMode: Bool) -> some View {
        if let info = mediaInfo {
            techSpecsSection(source: info, scopeMode: scopeMode)
        }
    }

    private func techSpecsSection(source: EmbyMediaSource, scopeMode: Bool) -> some View {
        // Extract outside ViewBuilder to avoid let-in-ViewBuilder issues
        let video  = source.videoStream
        let audios = source.audioStreams
        let subs   = source.subtitleStreams

        let videoValues: [String] = video.map { v in [
            v.resolutionLabel,
            v.codec?.uppercased(),
            v.hdrLabel,
            v.bitDepth.map { "\($0)-bit" },
            v.frameRate.map { String(format: "%.3g fps", $0) },
            formatBitrate(v.bitrate),
        ].compactMap { $0 } } ?? []

        let formatValues: [String] = [
            source.container?.uppercased(),
            source.size.map { formatFileSize($0) },
            formatBitrate(source.bitrate).map { "\($0) total" },
        ].compactMap { $0 }

        let audioValues: [String] = audios.prefix(3).compactMap { $0.audioLabel ?? $0.displayTitle }
        let audioLabel = audios.count == 1 ? "Audio" : "Audio (\(audios.count))"
        let subValues  = subs.isEmpty ? [] : [subs.compactMap { $0.language ?? $0.title }.prefix(6).joined(separator: ", ")]

        return VStack(alignment: .leading, spacing: 14) {
            Text("Technical")
                .font(.system(size: scopeMode ? 16 : 20, weight: .semibold))
                .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))

            VStack(alignment: .leading, spacing: scopeMode ? 6 : 10) {
                if !videoValues.isEmpty {
                    specRow(label: "Video", values: videoValues, scopeMode: scopeMode)
                }
                if !formatValues.isEmpty {
                    specRow(label: "Format", values: formatValues, scopeMode: scopeMode)
                }
                if !audioValues.isEmpty {
                    specRow(label: audioLabel, values: audioValues, scopeMode: scopeMode)
                }
                if !subValues.isEmpty {
                    specRow(label: "Subtitles", values: subValues, scopeMode: scopeMode)
                }
            }
        }
    }

    private func specRow(label: String, values: [String], scopeMode: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.system(size: scopeMode ? 12 : 14, weight: .semibold))
                .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                .frame(width: scopeMode ? 64 : 80, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.system(size: scopeMode ? 12 : 14, weight: .medium))
                        .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            CinemaTheme.surfaceNav(settings.colorMode),
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                }
            }
        }
    }

    private func formatBitrate(_ bps: Int?) -> String? {
        guard let bps else { return nil }
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bps) / 1_000_000)
        } else if bps >= 1_000 {
            return String(format: "%.0f kbps", Double(bps) / 1_000)
        }
        return "\(bps) bps"
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Load

    private func loadAll() async {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }

        // Step 1: Load Emby detail first
        if let loaded = try? await EmbyAPI.fetchItemDetail(
            server: server, userId: user.id, token: token, itemId: item.id) {
            detail = loaded
        }

        // Step 2a: If this is an episode, load sibling episodes from same season
        //          AND all seasons for the series (for the season picker).
        if (detail?.type ?? item.type) == "Episode" {
            if let seriesId = detail?.seriesId ?? item.seriesId,
               let seasonId = detail?.seasonId ?? item.seasonId {
                loadingCollection = true

                // Load all seasons so the picker above the ribbon is populated
                async let seasonsLoad = EmbyAPI.fetchSeasons(
                    server: server, userId: user.id, token: token, seriesId: seriesId)
                async let episodesLoad = EmbyAPI.fetchEpisodes(
                    server: server, userId: user.id, token: token,
                    seriesId: seriesId, seasonId: seasonId)

                if let fetched = try? await seasonsLoad {
                    episodeSeasons        = fetched
                    selectedEpisodeSeason = fetched.first(where: { $0.id == seasonId })
                }
                if let eps = try? await episodesLoad {
                    // Sort in episode order — the API doesn't guarantee it
                    collectionItems = eps.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
                }
                loadingCollection = false
            }
        }

        // Step 2: Load seasons if this is a Series
        if detail?.type == "Series" || item.type == "Series" {
            let seriesId = detail?.id ?? item.id
            if let fetchedSeasons = try? await EmbyAPI.fetchSeasons(
                server: server, userId: user.id, token: token, seriesId: seriesId) {
                seasons = fetchedSeasons
                selectedSeason = fetchedSeasons.first(where: {
                    ($0.userData?.played ?? false) == false
                }) ?? fetchedSeasons.first

                // Single season — fetch episodes immediately for inline ribbon
                if fetchedSeasons.count == 1, let onlySeason = fetchedSeasons.first {
                    if let eps = try? await EmbyAPI.fetchEpisodes(
                        server: server, userId: user.id, token: token,
                        seriesId: seriesId, seasonId: onlySeason.id) {
                        singleSeasonEpisodes = eps
                    }
                }
            }
        }

        // Step 3: Fetch media technical info
        if let info = try? await EmbyAPI.fetchMediaInfo(
            server: server, userId: user.id, token: token, itemId: detail?.id ?? item.id) {
            mediaInfo = info
        }

        // Step 4: Load collection siblings + collection name for movies/shows.
        // Skip for Episodes — their siblings were loaded correctly in Step 2a
        // and we don't want to overwrite them with unordered fetchCollectionItems results.
        let resolvedType = detail?.type ?? item.type
        if resolvedType != "Episode", let pid = detail?.parentId, !pid.isEmpty {
            loadingCollection = true
            // Fetch siblings and the BoxSet name in parallel
            async let nameLoad     = EmbyAPI.fetchItemDetail(server: server, userId: user.id, token: token, itemId: pid)
            async let siblingsLoad = EmbyAPI.fetchCollectionItems(server: server, userId: user.id, token: token, collectionId: pid)
            collectionName  = (try? await nameLoad)?.name
            collectionItems = (try? await siblingsLoad) ?? []
            loadingCollection = false
        }

        // Step 5: Enrich with TMDB — run last, failure is non-fatal
        // Use a detached task with timeout so a slow/failed TMDB
        // request never blocks or crashes the detail view
        let enrichItem = detail ?? item
        Task.detached(priority: .background) {
            let metadata = await TMDBAPI.metadata(for: enrichItem)
            await MainActor.run { self.tmdb = metadata }
        }
    }

    // MARK: - Episode ribbon scroll helper

    /// Scrolls the More Episodes ribbon to the current episode if it is in `episodes`,
    /// or to episode 1 when the user has switched to a different season.
    /// The brief delay lets SwiftUI finish layout before scrollTo runs.
    private func scrollToTarget(in episodes: [EmbyItem], proxy: ScrollViewProxy) {
        let episodes = episodes.filter { $0.type == "Episode" }
        let targetId = episodes.first(where: { $0.id == displayItem.id })?.id
                       ?? episodes.first?.id
        guard let targetId else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(targetId, anchor: .center)
            }
        }
    }

    // MARK: - Episode season switch

    /// Called when the user picks a different season from the More Episodes season picker.
    private func loadEpisodesForSeason(_ season: EmbyItem) async {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }
        guard let seriesId = detail?.seriesId ?? item.seriesId else { return }
        withAnimation(.easeInOut(duration: 0.2)) { loadingCollection = true }
        selectedEpisodeSeason = season
        if let eps = try? await EmbyAPI.fetchEpisodes(
            server: server, userId: user.id, token: token,
            seriesId: seriesId, seasonId: season.id) {
            collectionItems = eps.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
        }
        withAnimation { loadingCollection = false }
    }

    // MARK: - Helpers

    private func formatRuntime(_ minutes: Int) -> String {
        let h = minutes / 60; let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func scopeRect(in size: CGSize) -> CGRect {
        let h = size.width / CinemaTheme.scopeRatio
        let y = (size.height - h) / 2
        return CGRect(x: 0, y: y, width: size.width, height: h)
    }
}

// MARK: - CastCard

struct CastCard: View {
    let person:    EmbyPerson
    let session:   EmbySession
    let scopeMode: Bool
    let colorMode: ColorMode
    @FocusState private var isFocused: Bool

    private var size: CGFloat { scopeMode ? 64 : 88 }

    private var avatarURL: URL? {
        guard let server = session.server,
              let tag    = person.primaryImageTag else { return nil }
        return URL(string: "\(server.url)/Items/\(person.id)/Images/Primary?tag=\(tag)&width=\(Int(size * 2))")
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(CinemaTheme.cardGradient(colorMode))
                    .frame(width: size, height: size)
                if let url = avatarURL {
                    AsyncImage(url: url) { img in img.resizable().scaledToFill() }
                        placeholder: { initialsView }
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                } else {
                    initialsView
                }
            }
            .overlay {
                Circle().strokeBorder(
                    isFocused ? CinemaTheme.focusRimGradient(colorMode) :
                    LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                    lineWidth: 2
                )
            }
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: isFocused ? CinemaTheme.focusAccent(colorMode).opacity(0.5) : .clear, radius: 14)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)

            Text(person.name)
                .font(.system(size: scopeMode ? 11 : 13, weight: .medium))
                .foregroundStyle(CinemaTheme.primary(colorMode))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(width: size + 8)

            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(.system(size: scopeMode ? 10 : 11))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    .lineLimit(1)
                    .frame(width: size + 8)
            }
        }
        .focusEffectDisabled()
    }

    private var initialsView: some View {
        Text(person.name.prefix(1).uppercased())
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(CinemaTheme.tertiary(colorMode))
    }
}

// MARK: - CollectionItemCard

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
                        AsyncImage(url: url) { img in img.resizable().scaledToFill() }
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

// MARK: - DetailActionButton

struct DetailActionButton: View {
    enum Style { case primary, secondary, tertiary }
    let icon:      String
    let label:     String
    let style:     Style
    let scopeMode: Bool
    let isFocused: Bool
    let colorMode: ColorMode
    let action:    () -> Void

    private var radius: CGFloat { scopeMode ? 22 : 28 }

    // Base tint color per style
    private var tintColor: Color {
        switch style {
        case .primary:  return .white
        case .secondary: return CinemaTheme.peacock
        case .tertiary:  return CinemaTheme.peacockDeep
        }
    }

    // Outer glow color on focus
    // Dark mode: all buttons glow in peacock-feather teal
    // Light mode: primary keeps peacock, secondary/tertiary same
    private var glowColor: Color {
        switch style {
        case .primary:   return colorMode == .dark ? CinemaTheme.teal : CinemaTheme.peacock
        case .secondary: return CinemaTheme.teal
        case .tertiary:  return CinemaTheme.peacockLight
        }
    }

    // Base opacity — primary is brighter glass so it reads as the dominant CTA
    private var baseOpacity: Double {
        switch style {
        case .primary:  return isFocused ? 0.52 : 0.38
        case .secondary: return isFocused ? 0.28 : 0.14
        case .tertiary:  return isFocused ? 0.20 : 0.10
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: scopeMode ? 16 : 20, weight: .semibold))
                Text(label)
                    .font(.system(size: scopeMode ? 17 : 21, weight: .semibold))
            }
            // Primary keeps black text (bright glass base = enough contrast)
            // Secondary/tertiary use white on dark glass
            .foregroundStyle(style == .primary ? Color.black : Color.white)
            .padding(.horizontal, scopeMode ? 22 : 32)
            .padding(.vertical,   scopeMode ? 13 : 17)
            .background { glassBackground }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay { glassBorder }
            .scaleEffect(isFocused ? 1.06 : 1.0)
            // Wide color glow — the "light shining" signature
            .shadow(color: glowColor.opacity(isFocused ? 0.70 : 0), radius: 30, x: 0, y: 0)
            // Tight white upward shine — simulates reflected light above the button
            .shadow(color: Color.white.opacity(isFocused ? 0.22 : 0), radius: 8, x: 0, y: -5)
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: isFocused)
        }
        .focusRingFree()
    }

    // Three-layer glass fill: base tint + top specular + bottom edge reflection
    @ViewBuilder
    private var glassBackground: some View {
        ZStack {
            // 1. Base tint
            tintColor.opacity(baseOpacity)

            // 2. Top specular — overhead light hitting the top rim of the glass
            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(isFocused ? 0.60 : 0.30), location: 0.00),
                    .init(color: Color.white.opacity(isFocused ? 0.20 : 0.08), location: 0.42),
                    .init(color: Color.clear,                                   location: 0.72),
                ],
                startPoint: .top,
                endPoint:   .bottom
            )

            // 3. Bottom edge bounce — subtle second reflection at the base
            LinearGradient(
                stops: [
                    .init(color: Color.clear,                                    location: 0.65),
                    .init(color: Color.white.opacity(isFocused ? 0.14 : 0.05),  location: 1.00),
                ],
                startPoint: .top,
                endPoint:   .bottom
            )
        }
    }

    // Gradient stroke: bright at top-left (light source), dim at bottom-right (shadow)
    @ViewBuilder
    private var glassBorder: some View {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(isFocused ? 0.90 : 0.45), location: 0.00),
                        .init(color: Color.white.opacity(isFocused ? 0.45 : 0.20), location: 0.50),
                        .init(color: Color.white.opacity(isFocused ? 0.18 : 0.08), location: 1.00),
                    ],
                    startPoint: .topLeading,
                    endPoint:   .bottomTrailing
                ),
                lineWidth: isFocused ? 1.5 : 1.0
            )
    }
}


// MARK: - TMDBCastCard
// Uses TMDB profile photos and character names

struct TMDBCastCard: View {
    let member:    TMDBCastMember
    let scopeMode: Bool
    let colorMode: ColorMode
    @FocusState private var isFocused: Bool

    private var size: CGFloat { scopeMode ? 64 : 88 }
    private var profileURL: URL? { TMDBMetadata.profileURL(path: member.profilePath) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(CinemaTheme.cardGradient(colorMode))
                    .frame(width: size, height: size)

                if let url = profileURL {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: { initialsView }
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                } else {
                    initialsView
                }
            }
            .overlay {
                Circle().strokeBorder(
                    isFocused
                        ? CinemaTheme.focusRimGradient(colorMode)
                        : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                    lineWidth: 2
                )
            }
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: isFocused ? CinemaTheme.focusAccent(colorMode).opacity(0.5) : .clear, radius: 14)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)

            Text(member.name)
                .font(.system(size: scopeMode ? 11 : 13, weight: .medium))
                .foregroundStyle(CinemaTheme.primary(colorMode))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(width: size + 8)

            if let character = member.character, !character.isEmpty {
                Text(character)
                    .font(.system(size: scopeMode ? 10 : 11))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    .lineLimit(1)
                    .frame(width: size + 8)
            }
        }
        .focusEffectDisabled()
    }

    private var initialsView: some View {
        Text(member.name.prefix(1).uppercased())
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(CinemaTheme.tertiary(colorMode))
    }
}

// MARK: - SeasonCard

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
                        AsyncImage(url: url) { img in img.resizable().scaledToFill() }
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
// Compact 16:9 card used in the single-season inline ribbon on DetailView.

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
                            AsyncImage(url: url) { img in img.resizable().scaledToFill() }
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

// MARK: - SeasonPickerPill
//
// A single pill in the More Episodes season picker.
// Owns its own @FocusState so it can apply focus styling without
// the default tvOS white-box highlight that .buttonStyle(.plain) doesn't suppress.

private struct SeasonPickerPill: View {
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
