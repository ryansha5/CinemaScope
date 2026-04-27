import Foundation

// MARK: - ServerService
//
// User-scoped library connection: validates Emby credentials directly, then
// registers the connection with the PINEA backend.
//
// Architecture:
//   • Emby validation is client-side — fast and backend-agnostic
//   • PINEA backend stores the connection for cross-device / social features
//   • All PINEA calls are best-effort: if the backend is unreachable the local
//     Emby session still works and playback is unaffected
//
// Sprint 2 routes:
//   GET  /api/me/library-connection  — fetchConnectionStatus()
//   POST /api/me/library-connection  — connect() / storeConnectionBestEffort()

actor ServerService {

    static let shared = ServerService()
    private init() {}

    private enum Route {
        // Sprint 2 canonical routes
        static let libraryConnection = "/api/me/library-connection"
    }

    // MARK: - Sprint 2: fetchConnectionStatus
    //
    // GET /api/me/library-connection
    // Returns the stored library connection status for the authenticated user.

    func fetchConnectionStatus(baseURL: String, token: String) async throws -> PINEALibraryStatus {
        guard let url = URL(string: normalised(baseURL) + Route.libraryConnection) else {
            throw PINEAServiceError.invalidURL
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PINEAServiceError(message: "Could not fetch library connection status.")
        }
        return try JSONDecoder().decode(PINEALibraryStatus.self, from: data)
    }

    // MARK: - Sprint 2: connect
    //
    // Validates credentials with Emby directly, then POSTs to
    // /api/me/library-connection to register the connection on the PINEA backend.
    // Returns the validated Emby triple for immediate local session hydration.

    func connect(
        baseURL:   String,
        token:     String,
        serverURL: String,
        username:  String,
        password:  String
    ) async throws -> (server: EmbyServer, user: EmbyUser, token: String) {
        let server = EmbyServer(url: normalised(serverURL))
        let auth   = try await EmbyAPI.authenticate(
            server:   server,
            username: username,
            password: password
        )
        await storeConnectionBestEffort(
            baseURL:    baseURL,
            token:      token,
            serverURL:  server.url,
            embyUserId: auth.user.id,
            embyToken:  auth.accessToken
        )
        return (server, auth.user, auth.accessToken)
    }

    // MARK: - Legacy shim
    //
    // Keeps ServerSetupView compiling without modification — forwards to connect().

    func connectLibrary(
        pineaBaseURL:  String,
        pineaToken:    String,
        embyServerURL: String,
        embyUsername:  String,
        embyPassword:  String
    ) async throws -> (server: EmbyServer, user: EmbyUser, token: String) {
        try await connect(
            baseURL:   pineaBaseURL,
            token:     pineaToken,
            serverURL: embyServerURL,
            username:  embyUsername,
            password:  embyPassword
        )
    }

    // MARK: - Private

    private func storeConnectionBestEffort(
        baseURL:    String,
        token:      String,
        serverURL:  String,
        embyUserId: String,
        embyToken:  String
    ) async {
        guard let url = URL(string: normalised(baseURL) + Route.libraryConnection) else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        let body = PINEALibraryConnectionRequest(
            serverURL:  serverURL,
            embyUserId: embyUserId,
            embyToken:  embyToken
        )
        req.httpBody = try? JSONEncoder().encode(body)
        _ = try? await URLSession.shared.data(for: req)
    }

    private func normalised(_ url: String) -> String {
        url.hasSuffix("/") ? String(url.dropLast()) : url
    }
}
