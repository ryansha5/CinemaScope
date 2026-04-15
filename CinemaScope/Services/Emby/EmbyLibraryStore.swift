import Foundation

@MainActor
final class EmbyLibraryStore: ObservableObject {

    // Static library data (for grid views)
    @Published private(set) var movieItems:   [EmbyItem] = []
    @Published private(set) var showItems:    [EmbyItem] = []
    @Published private(set) var collections:  [EmbyItem] = []
    @Published private(set) var playlists:    [EmbyItem] = []

    // Dynamic ribbon data keyed by RibbonType.id
    @Published private(set) var ribbonItems: [String: [EmbyItem]] = [:]

    // Available genres from the library
    @Published private(set) var availableGenres: [String] = []

    @Published private(set) var isLoading = false
    @Published private(set) var error:     String? = nil

    private var movieLibraryId:      String? = nil
    private var showLibraryId:       String? = nil
    private var collectionLibraryId: String? = nil
    private var playlistLibraryId:   String? = nil

    // MARK: - Initial Load

    func load(server: EmbyServer, userId: String, token: String,
              ribbons: [HomeRibbon]) async {
        isLoading = true
        error     = nil

        do {
            let libraries = try await EmbyAPI.fetchLibraries(server: server, userId: userId, token: token)
            movieLibraryId      = libraries.first(where: { $0.collectionType == "movies"    })?.id
            showLibraryId       = libraries.first(where: { $0.collectionType == "tvshows"   })?.id
            collectionLibraryId = libraries.first(where: { $0.collectionType == "boxsets"   })?.id
            playlistLibraryId   = libraries.first(where: { $0.collectionType == "playlists" })?.id

            // Load full grids in parallel
            async let allMovies      = fetchAllIfAvailable(server: server, userId: userId, token: token, parentId: movieLibraryId)
            async let allShows       = fetchAllIfAvailable(server: server, userId: userId, token: token, parentId: showLibraryId)
            async let allCollections = fetchAllIfAvailable(server: server, userId: userId, token: token, parentId: collectionLibraryId)
            async let allPlaylists   = fetchAllIfAvailable(server: server, userId: userId, token: token, parentId: playlistLibraryId)

            movieItems   = try await allMovies
            showItems    = try await allShows
            collections  = try await allCollections
            playlists    = try await allPlaylists

            // Load genres
            async let movieGenres = (try? EmbyAPI.fetchGenres(server: server, userId: userId, token: token, itemType: "Movie")) ?? []
            async let showGenres  = (try? EmbyAPI.fetchGenres(server: server, userId: userId, token: token, itemType: "Series")) ?? []
            let mg = await movieGenres
            let sg = await showGenres
            availableGenres = Array(Set(mg + sg)).sorted()

            // Load ribbon data
            await loadRibbons(ribbons, server: server, userId: userId, token: token)

            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading  = false
        }
    }

    // MARK: - Ribbon Loading

    func loadRibbons(_ ribbons: [HomeRibbon], server: EmbyServer, userId: String, token: String) async {
        await withTaskGroup(of: (String, [EmbyItem]).self) { group in
            for ribbon in ribbons where ribbon.enabled {
                group.addTask {
                    let items = await self.fetchRibbonItems(
                        ribbon, server: server, userId: userId, token: token
                    )
                    return (ribbon.type.id, items)
                }
            }
            for await (key, items) in group {
                ribbonItems[key] = items
            }
        }
    }

    func reloadRibbon(_ ribbon: HomeRibbon, server: EmbyServer, userId: String, token: String) async {
        let items = await fetchRibbonItems(ribbon, server: server, userId: userId, token: token)
        ribbonItems[ribbon.type.id] = items
    }

    // MARK: - Private: fetch per ribbon type

    private func fetchRibbonItems(
        _ ribbon: HomeRibbon,
        server: EmbyServer, userId: String, token: String
    ) async -> [EmbyItem] {
        do {
            switch ribbon.type {
            case .continueWatching:
                return try await EmbyAPI.fetchContinueWatching(server: server, userId: userId, token: token, limit: 25)
            case .recentMovies:
                guard let id = movieLibraryId else { return [] }
                return try await EmbyAPI.fetchRecentlyAdded(server: server, userId: userId, token: token, parentId: id, limit: 25)
            case .recentTV:
                guard let id = showLibraryId else { return [] }
                return try await EmbyAPI.fetchRecentlyAdded(server: server, userId: userId, token: token, parentId: id, limit: 25)
            case .movies:
                guard let id = movieLibraryId else { return [] }
                return try await EmbyAPI.fetchItems(server: server, userId: userId, token: token, parentId: id, limit: 25).items
            case .tvShows:
                guard let id = showLibraryId else { return [] }
                return try await EmbyAPI.fetchItems(server: server, userId: userId, token: token, parentId: id, limit: 25).items
            case .collections:
                guard let id = collectionLibraryId else { return [] }
                return try await EmbyAPI.fetchItems(server: server, userId: userId, token: token, parentId: id, limit: 25).items
            case .playlists:
                guard let id = playlistLibraryId else { return [] }
                return try await EmbyAPI.fetchItems(server: server, userId: userId, token: token, parentId: id, limit: 25).items
            case .genre(let name, let itemType):
                return try await EmbyAPI.fetchByGenre(server: server, userId: userId, token: token, genre: name, itemType: itemType, limit: 25)
            case .recommended:
                return try await EmbyAPI.fetchRecommended(server: server, userId: userId, token: token, limit: 25)
            }
        } catch {
            return []
        }
    }

    // MARK: - Private helpers

    private func fetchAllIfAvailable(server: EmbyServer, userId: String, token: String, parentId: String?) async throws -> [EmbyItem] {
        guard let parentId else { return [] }
        return try await EmbyAPI.fetchItems(server: server, userId: userId, token: token, parentId: parentId, limit: 10000).items
    }
}
