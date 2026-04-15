import SwiftUI

struct CollectionDetailView: View {

    let collection: EmbyItem
    let session:    EmbySession
    let onSelect:   (EmbyItem) -> Void
    let onBack:     () -> Void

    @EnvironmentObject var settings: AppSettings
    @State private var allItems:  [EmbyItem] = []
    @State private var isLoading = true
    @State private var error:    String?    = nil

    private var movies: [EmbyItem] { allItems.filter { $0.type == "Movie"  } }
    private var shows:  [EmbyItem] { allItems.filter { $0.type == "Series" } }
    private var mixed:  Bool       { !movies.isEmpty && !shows.isEmpty }

    var body: some View {
        if settings.scopeUIEnabled {
            scopeShell
        } else {
            standardShell
        }
    }

    // MARK: - Standard shell (full screen)

    private var standardShell: some View {
        ZStack {
            CinemaBackground()
            VStack(alignment: .leading, spacing: 0) {
                header.focusSection()
                Divider().background(CinemaTheme.border(settings.colorMode))
                content
            }
        }
        .task { await loadItems() }
    }

    // MARK: - Scope shell (constrained to 2.39:1 canvas, true black bars)

    private var scopeShell: some View {
        GeometryReader { geo in
            let h = geo.size.width / CinemaTheme.scopeRatio
            let y = (geo.size.height - h) / 2
            let canvas = CGRect(x: 0, y: y, width: geo.size.width, height: h)

            VStack(spacing: 0) {
                // Top black bar
                Color.black.frame(height: canvas.minY)

                // Canvas
                ZStack {
                    CinemaTheme.backgroundGradient(settings.colorMode)
                    CinemaTheme.radialOverlay(settings.colorMode)
                    VStack(alignment: .leading, spacing: 0) {
                        header.focusSection()
                        Divider().background(CinemaTheme.border(settings.colorMode))
                        content
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
                .clipped()

                // Bottom black bar
                Color.black
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .task { await loadItems() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 32) {
            if let server = session.server,
               let tag    = collection.imageTags?.primary,
               let url    = EmbyAPI.primaryImageURL(server: server, itemId: collection.id, tag: tag, width: 200) {
                AsyncImage(url: url) { img in img.resizable().scaledToFill() }
                    placeholder: { RoundedRectangle(cornerRadius: 8).fill(CinemaTheme.cardGradient(settings.colorMode)) }
                .frame(width: settings.scopeUIEnabled ? 56 : 80,
                       height: settings.scopeUIEnabled ? 84 : 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.4), radius: 12)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(collection.name)
                    .font(settings.scopeUIEnabled ? .system(size: 28, weight: .bold) : CinemaTheme.titleFont)
                    .foregroundStyle(CinemaTheme.primary(settings.colorMode))
                    .lineLimit(1)
                if !allItems.isEmpty {
                    HStack(spacing: 10) {
                        if !movies.isEmpty { countBadge("\(movies.count) Movie\(movies.count == 1 ? "" : "s")") }
                        if !shows.isEmpty  { countBadge("\(shows.count) Show\(shows.count == 1 ? "" : "s")") }
                        if movies.isEmpty && shows.isEmpty { countBadge("\(allItems.count) Items") }
                    }
                }
                if let overview = collection.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: settings.scopeUIEnabled ? 13 : 16))
                        .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
                        .lineLimit(2)
                        .frame(maxWidth: settings.scopeUIEnabled ? 500 : 700, alignment: .leading)
                }
            }

            Spacer()

            // Back button with proper hover state
            BackButton(colorMode: settings.colorMode, scopeMode: settings.scopeUIEnabled, onTap: onBack)
        }
        .padding(.horizontal, settings.scopeUIEnabled ? 24 : CinemaTheme.pagePadding)
        .padding(.vertical, settings.scopeUIEnabled ? 16 : 36)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Spacer()
            HStack { Spacer(); ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.5); Spacer() }
            Spacer()
        } else if let error {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 48)).foregroundStyle(.yellow)
                Text(error).foregroundStyle(CinemaTheme.secondary(settings.colorMode))
            }.frame(maxWidth: .infinity)
            Spacer()
        } else if allItems.isEmpty {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "rectangle.stack").font(.system(size: 64))
                    .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
                Text("This collection is empty").font(CinemaTheme.bodyFont)
                    .foregroundStyle(CinemaTheme.tertiary(settings.colorMode))
            }.frame(maxWidth: .infinity)
            Spacer()
        } else if mixed {
            mixedRibbonView.focusSection()
        } else {
            singleTypeGrid.focusSection()
        }
    }

    // MARK: - Mixed ribbons

    private var mixedRibbonView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: settings.scopeUIEnabled ? 28 : 48) {
                if !movies.isEmpty { ribbon(title: "Movies",   items: movies) }
                if !shows.isEmpty  { ribbon(title: "TV Shows", items: shows)  }
            }
            .padding(.horizontal, settings.scopeUIEnabled ? 24 : CinemaTheme.pagePadding)
            .padding(.vertical, 24).padding(.bottom, 60)
        }
        .clipped(antialiased: false)
    }

    private func ribbon(title: String, items: [EmbyItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(settings.scopeUIEnabled ? .system(size: 20, weight: .semibold) : CinemaTheme.sectionFont)
                .foregroundStyle(CinemaTheme.primary(settings.colorMode))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: settings.scopeUIEnabled ? 12 : CinemaTheme.cardSpacing) {
                    ForEach(items) { item in
                        GridCard(item: item, session: session,
                                 scopeMode: settings.scopeUIEnabled) { onSelect(item) }
                    }
                }
                .padding(.vertical, 20).padding(.horizontal, 4)
            }
            .clipped(antialiased: false)
        }
    }

    // MARK: - Single type grid

    private var singleTypeGrid: some View {
        let scope   = settings.scopeUIEnabled
        let count   = scope ? 7 : 5
        let spacing: CGFloat = scope ? 12 : CinemaTheme.cardSpacing
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: scope ? 14 : CinemaTheme.cardSpacing) {
                ForEach(allItems) { item in
                    GridCard(item: item, session: session, scopeMode: scope) { onSelect(item) }
                }
            }
            .padding(.horizontal, scope ? 24 : CinemaTheme.pagePadding)
            .padding(.vertical, 24).padding(.bottom, 60)
        }
        .clipped(antialiased: false)
    }

    // MARK: - Helpers

    private func countBadge(_ text: String) -> some View {
        Text(text)
            .font(CinemaTheme.captionFont)
            .foregroundStyle(CinemaTheme.secondary(settings.colorMode))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(CinemaTheme.surfaceNav(settings.colorMode), in: RoundedRectangle(cornerRadius: 6))
    }

    private func loadItems() async {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }
        isLoading = true
        do {
            allItems  = try await EmbyAPI.fetchCollectionItems(
                server: server, userId: user.id, token: token, collectionId: collection.id)
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading  = false
        }
    }
}
