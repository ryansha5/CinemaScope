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

    // Personalized recommendation cards (paired recommendation + seed)
    @Published private(set) var recommendationItems: [RecommendationItem] = []

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

            // Load ribbon data + personalized recommendations in parallel
            async let ribbonLoad = loadRibbons(ribbons, server: server, userId: userId, token: token)
            async let recsLoad   = (try? EmbyAPI.fetchPersonalizedRecommendations(
                server: server, userId: userId, token: token, limit: 5)) ?? []
            await ribbonLoad
            recommendationItems = await recsLoad

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
            case .nextUp:
                return try await EmbyAPI.fetchNextUp(server: server, userId: userId, token: token)
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
            case .favorites:
                return try await EmbyAPI.fetchFavorites(server: server, userId: userId, token: token)
            case .genre(let name, let itemType):
                return try await EmbyAPI.fetchByGenre(server: server, userId: userId, token: token, genre: name, itemType: itemType, limit: 25)
            case .recommended:
                // Recommendation cards are loaded separately into recommendationItems;
                // return empty here so the generic MediaRow path is never triggered.
                return []
            }
        } catch {
            return []
        }
    }

    // MARK: - Favorites toggle

    func toggleFavorite(
        item: EmbyItem, server: EmbyServer, userId: String, token: String
    ) async {
        let newState = !(item.userData?.isFavorite ?? false)
        // Optimistic local update — feels instant on the couch
        patchFavorite(itemId: item.id, isFavorite: newState)

        do {
            let updatedData = try await EmbyAPI.toggleFavorite(
                server: server, userId: userId, token: token,
                itemId: item.id, isFavorite: newState
            )
            // Reconcile with what the server actually returned
            patchUserData(itemId: item.id, newData: updatedData)

            // Refresh the favorites ribbon so the row stays in sync
            let favRibbon = HomeRibbon(type: .favorites)
            await reloadRibbon(favRibbon, server: server, userId: userId, token: token)
        } catch {
            // Roll back on failure
            patchFavorite(itemId: item.id, isFavorite: !newState)
            print("[Store] toggleFavorite failed: \(error)")
        }
    }

    private func patchFavorite(itemId: String, isFavorite: Bool) {
        func patch(_ items: inout [EmbyItem]) {
            if let idx = items.firstIndex(where: { $0.id == itemId }) {
                let old = items[idx].userData
                let patched = UserData(
                    playbackPositionTicks: old?.playbackPositionTicks,
                    played: old?.played,
                    isFavorite: isFavorite
                )
                items[idx] = items[idx].withUserData(patched)
            }
        }
        patch(&movieItems)
        patch(&showItems)
        for key in ribbonItems.keys {
            if var arr = ribbonItems[key] { patch(&arr); ribbonItems[key] = arr }
        }
    }

    private func patchUserData(itemId: String, newData: UserData) {
        func patch(_ items: inout [EmbyItem]) {
            if let idx = items.firstIndex(where: { $0.id == itemId }) {
                items[idx] = items[idx].withUserData(newData)
            }
        }
        patch(&movieItems)
        patch(&showItems)
        for key in ribbonItems.keys {
            if var arr = ribbonItems[key] { patch(&arr); ribbonItems[key] = arr }
        }
    }

    // MARK: - Local userData patch
    //
    // After playback stops, immediately update the stored position so that
    // Play/Resume CTAs and progress bars reflect reality without waiting for
    // the next server fetch.  The server receives the authoritative stop report
    // via EmbyAPI.reportPlaybackStop; this is purely a local UI update.

    func updatePlaybackPosition(itemId: String, positionTicks: Int64) {
        // Preserve isFavorite when patching playback position
        let existing = ribbonItems.values.flatMap { $0 }.first(where: { $0.id == itemId })
            ?? movieItems.first(where: { $0.id == itemId })
            ?? showItems.first(where: { $0.id == itemId })
        let patchedData = UserData(
            playbackPositionTicks: positionTicks > 0 ? positionTicks : nil,
            played: false,
            isFavorite: existing?.userData?.isFavorite
        )

        func patch(_ items: inout [EmbyItem]) {
            if let idx = items.firstIndex(where: { $0.id == itemId }) {
                items[idx] = items[idx].withUserData(patchedData)
            }
        }

        patch(&movieItems)
        patch(&showItems)
        patch(&collections)
        patch(&playlists)

        // Patch inside ribbon arrays too (Continue Watching, Recently Added, etc.)
        for key in ribbonItems.keys {
            if var arr = ribbonItems[key] {
                patch(&arr)
                ribbonItems[key] = arr
            }
        }

        // Re-apply the Continue Watching filter after patching so finished
        // items drop out of the row immediately.
        let cwKey = RibbonType.continueWatching.id
        if let cwArr = ribbonItems[cwKey] {
            ribbonItems[cwKey] = cwArr.filter { PlaybackCTA.shouldShowInContinueWatching($0) }
        }
    }

    // MARK: - Private helpers

    private func fetchAllIfAvailable(server: EmbyServer, userId: String, token: String, parentId: String?) async throws -> [EmbyItem] {
        guard let parentId else { return [] }
        return try await EmbyAPI.fetchItems(server: server, userId: userId, token: token, parentId: parentId, limit: 10000).items
    }
}
