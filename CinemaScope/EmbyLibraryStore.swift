import Foundation

@MainActor
final class EmbyLibraryStore: ObservableObject {

    // Home screen ribbons — capped at 25
    @Published private(set) var continueWatchingItems: [EmbyItem] = []
    @Published private(set) var recentMovies:          [EmbyItem] = []
    @Published private(set) var recentShows:           [EmbyItem] = []
    @Published private(set) var homeMovies:            [EmbyItem] = []
    @Published private(set) var homeShows:             [EmbyItem] = []

    // Full section grids — no limit
    @Published private(set) var movieItems:   [EmbyItem] = []
    @Published private(set) var showItems:    [EmbyItem] = []
    @Published private(set) var collections:  [EmbyItem] = []
    @Published private(set) var playlists:    [EmbyItem] = []

    @Published private(set) var isLoading = false
    @Published private(set) var error:     String? = nil

    private var movieLibraryId:      String? = nil
    private var showLibraryId:       String? = nil
    private var collectionLibraryId: String? = nil
    private var playlistLibraryId:   String? = nil

    func load(server: EmbyServer, userId: String, token: String) async {
        isLoading = true
        error     = nil

        do {
            let libraries = try await EmbyAPI.fetchLibraries(
                server: server, userId: userId, token: token
            )
            movieLibraryId      = libraries.first(where: { $0.collectionType == "movies"    })?.id
            showLibraryId       = libraries.first(where: { $0.collectionType == "tvshows"   })?.id
            collectionLibraryId = libraries.first(where: { $0.collectionType == "boxsets"   })?.id
            playlistLibraryId   = libraries.first(where: { $0.collectionType == "playlists" })?.id

            // Home ribbons — fetch in parallel, capped at 25
            async let continueWatching = EmbyAPI.fetchContinueWatching(
                server: server, userId: userId, token: token, limit: 25
            )
            async let recentM = fetchRecentIfAvailable(
                server: server, userId: userId, token: token, parentId: movieLibraryId, limit: 25
            )
            async let recentS = fetchRecentIfAvailable(
                server: server, userId: userId, token: token, parentId: showLibraryId, limit: 25
            )
            async let homeM = fetchIfAvailable(
                server: server, userId: userId, token: token, parentId: movieLibraryId, limit: 25
            )
            async let homeS = fetchIfAvailable(
                server: server, userId: userId, token: token, parentId: showLibraryId, limit: 25
            )

            // Full grids — no limit (pass 0 to mean unlimited)
            async let allMovies = fetchAllIfAvailable(
                server: server, userId: userId, token: token, parentId: movieLibraryId
            )
            async let allShows = fetchAllIfAvailable(
                server: server, userId: userId, token: token, parentId: showLibraryId
            )
            async let allCollections = fetchAllIfAvailable(
                server: server, userId: userId, token: token, parentId: collectionLibraryId
            )
            async let allPlaylists = fetchAllIfAvailable(
                server: server, userId: userId, token: token, parentId: playlistLibraryId
            )

            continueWatchingItems = try await continueWatching
            recentMovies          = try await recentM
            recentShows           = try await recentS
            homeMovies            = try await homeM
            homeShows             = try await homeS
            movieItems            = try await allMovies
            showItems             = try await allShows
            collections           = try await allCollections
            playlists             = try await allPlaylists
            isLoading             = false

        } catch {
            self.error = error.localizedDescription
            isLoading  = false
        }
    }

    // MARK: - Private helpers

    private func fetchIfAvailable(
        server: EmbyServer, userId: String, token: String,
        parentId: String?, limit: Int
    ) async throws -> [EmbyItem] {
        guard let parentId else { return [] }
        let response = try await EmbyAPI.fetchItems(
            server: server, userId: userId, token: token,
            parentId: parentId, limit: limit
        )
        return response.items
    }

    private func fetchAllIfAvailable(
        server: EmbyServer, userId: String, token: String,
        parentId: String?
    ) async throws -> [EmbyItem] {
        guard let parentId else { return [] }
        let response = try await EmbyAPI.fetchItems(
            server: server, userId: userId, token: token,
            parentId: parentId, limit: 10000
        )
        return response.items
    }

    private func fetchRecentIfAvailable(
        server: EmbyServer, userId: String, token: String,
        parentId: String?, limit: Int
    ) async throws -> [EmbyItem] {
        guard let parentId else { return [] }
        return try await EmbyAPI.fetchRecentlyAdded(
            server: server, userId: userId, token: token,
            parentId: parentId, limit: limit
        )
    }
}
