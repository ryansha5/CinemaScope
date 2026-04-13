import SwiftUI

struct SearchView: View {

    let session:   EmbySession
    let onSelect:  (EmbyItem) -> Void
    let onDismiss: () -> Void

    @State private var query      = ""
    @State private var results:   [EmbyItem] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>? = nil

    let columns = Array(repeating: GridItem(.flexible(), spacing: CinemaTheme.cardSpacing), count: 5)

    var body: some View {
        ZStack {
            CinemaBackground()

            VStack(alignment: .leading, spacing: 40) {
                // Header row
                HStack(spacing: 32) {
                    HStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(CinemaTheme.peacockLight)
                        TextField("Search movies, shows, collections…", text: $query)
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: query) { _, new in scheduleSearch(query: new) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .background(CinemaTheme.peacockDeep.opacity(0.6),
                                in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(CinemaTheme.peacockLight.opacity(0.3), lineWidth: 1)
                    }
                    .frame(maxWidth: 800)

                    Button("Cancel") { onDismiss() }
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .focusRingFree()
                }

                // Results area
                if isSearching {
                    Spacer()
                    HStack { Spacer(); ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.3); Spacer() }
                    Spacer()
                } else if hasSearched && results.isEmpty {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass").font(.system(size: 48)).foregroundStyle(.white.opacity(0.2))
                            Text("No results for \u{201C}\(query)\u{201D}").font(CinemaTheme.bodyFont).foregroundStyle(.white.opacity(0.4))
                        }
                        Spacer()
                    }
                    Spacer()
                } else if !results.isEmpty {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: CinemaTheme.cardSpacing) {
                            ForEach(results) { item in
                                GridCard(item: item, session: session, scopeMode: false) { onSelect(item) }
                            }
                        }
                        .padding(.bottom, 60)
                    }
                } else {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass").font(.system(size: 64)).foregroundStyle(.white.opacity(0.1))
                            Text("Start typing to search your library").font(CinemaTheme.bodyFont).foregroundStyle(.white.opacity(0.3))
                        }
                        Spacer()
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, CinemaTheme.pagePadding)
            .padding(.top, 60)
        }
    }

    private func scheduleSearch(query: String) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []; hasSearched = false; return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
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
        } catch {
            results = []
        }
        isSearching = false
    }
}
