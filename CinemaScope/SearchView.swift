import SwiftUI

struct SearchView: View {

    let session:   EmbySession
    let onSelect:  (EmbyItem) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject var settings: AppSettings
    @State private var query        = ""
    @State private var results:     [EmbyItem] = []
    @State private var isSearching  = false
    @State private var hasSearched  = false
    @State private var searchTask:  Task<Void, Never>? = nil

    var body: some View {
        if settings.scopeUIEnabled { scopeShell } else { standardShell }
    }

    // MARK: - Shells

    private var standardShell: some View {
        ZStack(alignment: .top) {
            CinemaBackground()
            VStack(alignment: .leading, spacing: 36) {
                searchBar
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
                    VStack(alignment: .leading, spacing: 24) {
                        searchBar
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
                    Button { query = ""; results = []; hasSearched = false } label: {
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

    // MARK: - Results

    @ViewBuilder
    private func resultsArea(scopeMode: Bool) -> some View {
        let cols  = scopeMode ? 6 : 5
        let space: CGFloat = scopeMode ? 12 : CinemaTheme.cardSpacing
        let columns = Array(repeating: GridItem(.flexible(), spacing: space), count: cols)

        if isSearching {
            Spacer()
            HStack { Spacer(); ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.3); Spacer() }
            Spacer()
        } else if hasSearched && results.isEmpty {
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
        } else if !results.isEmpty {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: space) {
                    ForEach(results) { item in
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

    // MARK: - Search logic

    private func scheduleSearch(query: String) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []; hasSearched = false; return
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
        do {
            results     = try await EmbyAPI.search(server: server, userId: user.id, token: token, query: query)
            hasSearched = true
        } catch { results = [] }
        isSearching = false
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
                            AsyncImage(url: url) { img in img.resizable().scaledToFill() }
                                placeholder: { placeholder }
                        } else { placeholder }
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

                // Year + rating
                HStack(spacing: 6) {
                    if let year = item.productionYear {
                        Text("\(year)")
                            .font(.system(size: scopeMode ? 10 : 13))
                            .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    }
                    if let rating = item.communityRating {
                        Text(String(format: "★ %.1f", rating))
                            .font(.system(size: scopeMode ? 10 : 13))
                            .foregroundStyle(CinemaTheme.accentGold.opacity(0.85))
                    }
                }
            }
        }
        .focusRingFree()
        .focused($isFocused)
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
