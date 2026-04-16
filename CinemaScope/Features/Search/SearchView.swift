import SwiftUI

// MARK: - SearchScope

enum SearchScope: String, CaseIterable {
    case all, movies, tv, collections

    var displayName: String {
        switch self {
        case .all:         return "All"
        case .movies:      return "Movies"
        case .tv:          return "TV"
        case .collections: return "Collections"
        }
    }

    var includeItemTypes: String {
        switch self {
        case .all:         return "Movie,Series,BoxSet,Playlist"
        case .movies:      return "Movie"
        case .tv:          return "Series"
        case .collections: return "BoxSet"
        }
    }
}

// MARK: - SearchSort

enum SearchSort: String, CaseIterable {
    case relevance, az, year, rating, random

    var displayName: String {
        switch self {
        case .relevance: return "Relevance"
        case .az:        return "A–Z"
        case .year:      return "Year"
        case .rating:    return "Rating"
        case .random:    return "Random"
        }
    }

    var icon: String {
        switch self {
        case .relevance: return "text.magnifyingglass"
        case .az:        return "textformat.abc"
        case .year:      return "calendar"
        case .rating:    return "star.fill"
        case .random:    return "shuffle"
        }
    }
}

// MARK: - SearchView

struct SearchView: View {

    let session:   EmbySession
    let genres:    [String]
    let onSelect:  (EmbyItem) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject var settings: AppSettings

    // Search state
    @State private var query:          String        = ""
    @State private var scope:          SearchScope   = .all
    @State private var sortOrder:      SearchSort    = .relevance
    @State private var results:        [EmbyItem]    = []
    @State private var displayResults: [EmbyItem]    = []
    @State private var isSearching:    Bool          = false
    @State private var hasSearched:    Bool          = false
    @State private var searchError:    Bool          = false
    @State private var searchTask:     Task<Void, Never>? = nil

    var body: some View {
        if settings.scopeUIEnabled { scopeShell } else { standardShell }
    }

    // MARK: - Shells

    private var standardShell: some View {
        ZStack(alignment: .top) {
            CinemaBackground()
            VStack(alignment: .leading, spacing: 20) {
                searchBar
                scopePills(scopeMode: false)
                if !displayResults.isEmpty {
                    sortBar(scopeMode: false)
                }
                resultsArea(scopeMode: false)
            }
            .padding(.horizontal, CinemaTheme.pagePadding)
            .padding(.top, 60)
        }
    }

    private var scopeShell: some View {
        GeometryReader { geo in
            let h = geo.size.width / CinemaTheme.scopeRatio
            let y = (geo.size.height - h) / 2
            let canvas = CGRect(x: 0, y: y, width: geo.size.width, height: h)
            VStack(spacing: 0) {
                Color.black.frame(height: canvas.minY)
                ZStack(alignment: .top) {
                    CinemaTheme.backgroundGradient(settings.colorMode)
                    CinemaTheme.radialOverlay(settings.colorMode)
                    VStack(alignment: .leading, spacing: 14) {
                        searchBar
                        scopePills(scopeMode: true)
                        if !displayResults.isEmpty {
                            sortBar(scopeMode: true)
                        }
                        resultsArea(scopeMode: true)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                }
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
                Color.black
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: settings.scopeUIEnabled ? 18 : 22))
                    .foregroundStyle(CinemaTheme.peacockLight)
                TextField("Search movies, shows, collections…", text: $query)
                    .font(.system(size: settings.scopeUIEnabled ? 18 : 24))
                    .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: query) { _, new in scheduleSearch(query: new) }
                if !query.isEmpty {
                    Button {
                        query = ""; results = []; displayResults = []
                        hasSearched = false; searchError = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                    }
                    .focusRingFree()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, settings.scopeUIEnabled ? 14 : 18)
            .background(CinemaTheme.surfaceNav(settings.colorMode),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(CinemaTheme.border(settings.colorMode), lineWidth: 1)
            }
            .frame(maxWidth: settings.scopeUIEnabled ? 560 : 800)

            BackButton(colorMode: settings.colorMode,
                       scopeMode: settings.scopeUIEnabled,
                       onTap: onDismiss)
        }
    }

    // MARK: - Scope pills

    private func scopePills(scopeMode: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchScope.allCases, id: \.rawValue) { s in
                    SearchPill(
                        label:     s.displayName,
                        isActive:  scope == s,
                        colorMode: settings.colorMode,
                        scopeMode: scopeMode
                    ) {
                        guard scope != s else { return }
                        scope = s
                        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                            searchTask?.cancel()
                            Task { await performSearch(query: query) }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }

    // MARK: - Sort bar

    private func sortBar(scopeMode: Bool) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SearchSort.allCases, id: \.rawValue) { s in
                        SearchPill(
                            label:     s.displayName,
                            icon:      s.icon,
                            isActive:  sortOrder == s,
                            colorMode: settings.colorMode,
                            scopeMode: scopeMode,
                            small:     true
                        ) {
                            if sortOrder == s && s == .random {
                                // Re-shuffle if Random already selected
                                displayResults = results.shuffled()
                            } else {
                                sortOrder = s
                                applySort()
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()

            Spacer()

            // Result count
            Text("\(displayResults.count) result\(displayResults.count == 1 ? "" : "s")")
                .font(.system(size: scopeMode ? 11 : 13))
                .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                .padding(.leading, 12)
        }
    }

    // MARK: - Results area

    @ViewBuilder
    private func resultsArea(scopeMode: Bool) -> some View {
        let cols    = scopeMode ? 6 : 5
        let space: CGFloat = scopeMode ? 12 : CinemaTheme.cardSpacing
        let columns = Array(repeating: GridItem(.flexible(), spacing: space), count: cols)

        if isSearching {
            Spacer()
            HStack {
                Spacer()
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.3)
                Spacer()
            }
            Spacer()
        } else if searchError {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 48))
                    .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                Text("Couldn't reach your library")
                    .font(CinemaTheme.bodyFont)
                    .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
                Text("Check your server connection and try again")
                    .font(.system(size: 15))
                    .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
            }
            .frame(maxWidth: .infinity)
            Spacer()
        } else if hasSearched && displayResults.isEmpty {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                Text("No results for \"\(query)\"")
                    .font(CinemaTheme.bodyFont)
                    .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
            }
            .frame(maxWidth: .infinity)
            Spacer()
        } else if !displayResults.isEmpty {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: space) {
                    ForEach(displayResults) { item in
                        SearchResultCard(
                            item:      item,
                            session:   session,
                            scopeMode: scopeMode,
                            colorMode: settings.colorMode
                        ) { onSelect(item) }
                    }
                }
                .padding(.bottom, 60)
            }
            .clipped(antialiased: false)
        } else {
            // Idle — recent searches + genre shortcuts
            browseArea(scopeMode: scopeMode)
        }
    }

    // MARK: - Browse area (idle state)

    @ViewBuilder
    private func browseArea(scopeMode: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: scopeMode ? 20 : 28) {

                // Recent searches
                if !settings.recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Recent")
                                .font(.system(size: scopeMode ? 14 : 18, weight: .semibold))
                                .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
                            Spacer()
                            Button("Clear") { settings.clearRecentSearches() }
                                .font(.system(size: scopeMode ? 12 : 14))
                                .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                                .focusRingFree()
                        }
                        FlowLayout(spacing: 8) {
                            ForEach(settings.recentSearches, id: \.self) { term in
                                SearchPill(
                                    label:     term,
                                    icon:      "clock",
                                    isActive:  false,
                                    colorMode: settings.colorMode,
                                    scopeMode: scopeMode
                                ) {
                                    query = term
                                    scheduleSearch(query: term)
                                }
                            }
                        }
                    }
                }

                // Genre shortcuts
                if !genres.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Browse by genre")
                            .font(.system(size: scopeMode ? 14 : 18, weight: .semibold))
                            .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
                        FlowLayout(spacing: 8) {
                            ForEach(genres, id: \.self) { genre in
                                SearchPill(
                                    label:     genre,
                                    isActive:  false,
                                    colorMode: settings.colorMode,
                                    scopeMode: scopeMode
                                ) {
                                    query = genre
                                    scheduleSearch(query: genre)
                                }
                            }
                        }
                    }
                }

                // Cold-start prompt when nothing to show
                if settings.recentSearches.isEmpty && genres.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: scopeMode ? 48 : 64))
                            .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                        Text("Search your library")
                            .font(CinemaTheme.bodyFont)
                            .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 60)
        }
        .clipped(antialiased: false)
    }

    // MARK: - Search logic

    private func scheduleSearch(query: String) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []; displayResults = []
            hasSearched = false; searchError = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    @MainActor
    private func performSearch(query: String) async {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }
        isSearching = true
        searchError = false
        do {
            results = try await EmbyAPI.search(
                server: server, userId: user.id, token: token,
                query: query,
                includeItemTypes: scope.includeItemTypes
            )
            hasSearched = true
            applySort()
            settings.addRecentSearch(query)
        } catch {
            searchError = true
            results = []; displayResults = []
        }
        isSearching = false
    }

    private func applySort() {
        switch sortOrder {
        case .relevance: displayResults = results
        case .az:        displayResults = results.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .year:      displayResults = results.sorted { ($0.productionYear ?? 0) > ($1.productionYear ?? 0) }
        case .rating:    displayResults = results.sorted { ($0.communityRating ?? 0) > ($1.communityRating ?? 0) }
        case .random:    displayResults = results.shuffled()
        }
    }
}

// MARK: - SearchPill

struct SearchPill: View {
    let label:     String
    var icon:      String?   = nil
    let isActive:  Bool
    let colorMode: ColorMode
    let scopeMode: Bool
    var small:     Bool      = false
    let onTap:     () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: small ? (scopeMode ? 9 : 11) : (scopeMode ? 10 : 12)))
                }
                Text(label)
                    .font(.system(
                        size: small ? (scopeMode ? 10 : 12) : (scopeMode ? 12 : 14),
                        weight: isActive ? .semibold : .regular
                    ))
            }
            .foregroundStyle(isActive ? Color.black : (focused ? Color.black : CinemaTheme.secondary(colorMode)))
            .padding(.horizontal, small ? 10 : 14)
            .padding(.vertical, small ? 5 : 8)
            .background(
                isActive    ? CinemaTheme.accentGold :
                focused     ? CinemaTheme.accentGold.opacity(0.85) :
                CinemaTheme.surfaceNav(colorMode),
                in: Capsule()
            )
        }
        .focusRingFree()
        .focused($focused)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: - FlowLayout
// Wrapping horizontal layout for pill chips (genre tags, recent searches).

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowX: CGFloat   = 0
        var rowH: CGFloat   = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowX + size.width > width && rowX > 0 {
                height += rowH + spacing
                rowX = 0; rowH = 0
            }
            rowX += size.width + spacing
            rowH = max(rowH, size.height)
        }
        height += rowH
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var rowX: CGFloat = bounds.minX
        var rowY: CGFloat = bounds.minY
        var rowH: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowX + size.width > bounds.maxX && rowX > bounds.minX {
                rowY += rowH + spacing
                rowX = bounds.minX; rowH = 0
            }
            subview.place(at: CGPoint(x: rowX, y: rowY), proposal: ProposedViewSize(size))
            rowX += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

// MARK: - SearchResultCard
// Richer search result card with type badge, year, rating

struct SearchResultCard: View {
    let item:      EmbyItem
    let session:   EmbySession
    let scopeMode: Bool
    let colorMode: ColorMode
    let onTap:     () -> Void
    @FocusState private var isFocused: Bool

    private var posterURL: URL? {
        guard let server = session.server,
              let tag    = item.imageTags?.primary else { return nil }
        return EmbyAPI.primaryImageURL(server: server, itemId: item.id, tag: tag,
                                       width: scopeMode ? 200 : 300)
    }

    private var typeLabel: String {
        switch item.type {
        case "Series":   return "TV"
        case "Movie":    return "Movie"
        case "BoxSet":   return "Collection"
        case "Playlist": return "Playlist"
        default:         return item.type
        }
    }

    private var typeColor: Color {
        switch item.type {
        case "Series":  return CinemaTheme.peacockLight
        case "BoxSet":  return CinemaTheme.accentGold
        default:        return CinemaTheme.peacockLight.opacity(0.7)
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: scopeMode ? 6 : 8) {
                // Poster
                ZStack(alignment: .topLeading) {
                    Group {
                        if let url = posterURL {
                            CachedAsyncImage(url: url) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                placeholder
                            }
                        } else {
                            placeholder
                        }
                    }
                    .aspectRatio(2/3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: scopeMode ? 6 : 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: scopeMode ? 6 : 10)
                            .strokeBorder(
                                isFocused
                                    ? CinemaTheme.focusRimGradient(colorMode)
                                    : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                                lineWidth: isFocused ? 2.5 : 0
                            )
                    }

                    // Type badge
                    Text(typeLabel)
                        .font(.system(size: scopeMode ? 9 : 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(typeColor, in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
                .scaleEffect(isFocused ? 1.05 : 1.0, anchor: .bottom)
                .shadow(
                    color: isFocused ? CinemaTheme.focusAccent(colorMode).opacity(0.5) : .clear,
                    radius: 20, x: 0, y: 10
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.68), value: isFocused)

                // Title
                Text(item.name)
                    .font(.system(size: scopeMode ? 11 : 15, weight: .semibold))
                    .foregroundStyle(CinemaTheme.primary(colorMode))
                    .lineLimit(2)

                // Metadata row
                searchMetaRow(scopeMode: scopeMode)
            }
        }
        .focusRingFree()
        .focused($isFocused)
    }

    @ViewBuilder
    private func searchMetaRow(scopeMode: Bool) -> some View {
        let fontSize: CGFloat = scopeMode ? 10 : 13
        let parts: [AnyView] = buildMetaParts(fontSize: fontSize)
        if !parts.isEmpty {
            HStack(spacing: 4) {
                ForEach(parts.indices, id: \.self) { i in
                    if i > 0 {
                        Text("·")
                            .font(.system(size: fontSize))
                            .foregroundStyle(CinemaTheme.tertiary(colorMode).opacity(0.5))
                    }
                    parts[i]
                }
            }
        }
    }

    private func buildMetaParts(fontSize: CGFloat) -> [AnyView] {
        var parts: [AnyView] = []

        if let year = item.productionYear {
            parts.append(AnyView(
                Text("\(year)")
                    .font(.system(size: fontSize))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
            ))
        }

        if let mins = item.runtimeMinutes, item.type != "Series" && item.type != "BoxSet" {
            let str = mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
            parts.append(AnyView(
                Text(str)
                    .font(.system(size: fontSize))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
            ))
        }

        if item.type == "Series", let s = item.childCount, s > 0 {
            parts.append(AnyView(
                Text("\(s) Season\(s == 1 ? "" : "s")")
                    .font(.system(size: fontSize))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
            ))
        }

        if item.type == "BoxSet", let c = item.childCount, c > 0 {
            parts.append(AnyView(
                Text("\(c) Films")
                    .font(.system(size: fontSize))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
            ))
        }

        if let r = item.officialRating {
            parts.append(AnyView(
                Text(r)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(CinemaTheme.tertiary(colorMode).opacity(0.4), lineWidth: 1)
                    )
            ))
        }

        if let rating = item.communityRating {
            parts.append(AnyView(
                Text(String(format: "★ %.1f", rating))
                    .font(.system(size: fontSize))
                    .foregroundStyle(CinemaTheme.accentGold.opacity(0.85))
            ))
        }

        return parts
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: scopeMode ? 6 : 10)
                .fill(CinemaTheme.cardGradient(colorMode))
            Image(systemName: item.type == "Series" ? "tv" : "film")
                .font(.system(size: scopeMode ? 20 : 28))
                .foregroundStyle(CinemaTheme.tertiary(colorMode))
        }
    }
}
