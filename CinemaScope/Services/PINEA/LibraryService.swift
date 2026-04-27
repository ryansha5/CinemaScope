import Foundation

// MARK: - LibraryService
//
// Sprint 3: backend-backed library snapshot management.
// Provides read/sync access to the PINEA library snapshot — a backend-stored
// metadata index of the user's Emby collection.
//
// Architecture contract:
//   • Views never call this directly — always through PINEAEnvironment methods
//   • Playback remains direct-to-Emby; this service handles metadata only
//   • All calls are non-blocking and non-fatal when the backend is unreachable
//
// Routes:
//   GET  /api/me/library/status  — fetchLibraryStatus()
//   GET  /api/me/library         — fetchLibrary()
//   POST /api/me/library/sync    — syncLibrary()

actor LibraryService {

    static let shared = LibraryService()
    private init() {}

    private enum Route {
        static let status  = "/api/me/library/status"
        static let library = "/api/me/library"
        static let sync    = "/api/me/library/sync"
    }

    // MARK: - fetchLibraryStatus
    //
    // GET /api/me/library/status
    // Returns whether a backend snapshot exists and when it was last synced.

    func fetchLibraryStatus(
        baseURL: String,
        token:   String
    ) async throws -> PINEALibrarySnapshotStatus {
        let url = try endpoint(baseURL, Route.status)
        return try await get(url: url, token: token)
    }

    // MARK: - fetchLibrary
    //
    // GET /api/me/library
    // Returns the full lightweight metadata snapshot.
    // Used to populate in-memory libraryItems on the environment.

    func fetchLibrary(
        baseURL: String,
        token:   String
    ) async throws -> [PINEALibraryItem] {
        let url = try endpoint(baseURL, Route.library)
        let response: PINEALibraryResponse = try await get(url: url, token: token)
        return response.items
    }

    // MARK: - syncLibrary
    //
    // POST /api/me/library/sync
    // Triggers a backend re-index of the user's Emby library.
    // Returns the sync timestamp and updated item count.

    func syncLibrary(
        baseURL: String,
        token:   String
    ) async throws -> PINEASyncResponse {
        let url = try endpoint(baseURL, Route.sync)
        return try await post(url: url, token: token)
    }

    // MARK: - Private networking

    private func endpoint(_ base: String, _ path: String) throws -> URL {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: trimmed + path) else {
            throw PINEAServiceError.invalidURL
        }
        return url
    }

    private func get<T: Decodable>(url: URL, token: String) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(url: URL, token: String, body: Encodable? = nil) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try? JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PINEAServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["message"]
                   ?? (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                   ?? "Server returned \(http.statusCode)"
            throw PINEAServiceError(message: msg)
        }
    }

    // ISO-8601 decoder with fractional seconds support
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: string) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Cannot decode date: \(string)"
            )
        }
        return d
    }()
}
