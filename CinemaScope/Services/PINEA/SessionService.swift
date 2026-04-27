import Foundation

// MARK: - SessionService
//
// Sprint 5: lightweight backend session observation.
// Fetches the current session state for the authenticated user.
//
// Architecture contract:
//   • Read-only — PINEA does not write session state through this service yet
//   • Playback remains direct-to-Emby; session data is for awareness only
//   • No direct URL calls from views — always via PINEAEnvironment
//
// Route:
//   GET /api/me/session/current  — fetchCurrentSession()

actor SessionService {

    static let shared = SessionService()
    private init() {}

    private enum Route {
        static let current = "/api/me/session/current"
    }

    // MARK: - fetchCurrentSession
    //
    // Returns the current backend session for the user, or nil if none exists.
    // A 404 is treated as "no session" rather than an error.

    func fetchCurrentSession(
        baseURL: String,
        token:   String
    ) async throws -> PINEASession? {
        guard let url = endpoint(baseURL, Route.current) else {
            throw PINEAServiceError.invalidURL
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw PINEAServiceError.invalidResponse
        }

        // 404 = no active session — not an error condition
        if http.statusCode == 404 { return nil }

        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["message"]
                   ?? (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                   ?? "Server returned \(http.statusCode)"
            throw PINEAServiceError(message: msg)
        }

        let envelope = try decoder.decode(PINEASessionResponse.self, from: data)
        return envelope.session
    }

    // MARK: - Private

    private func endpoint(_ base: String, _ path: String) -> URL? {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: trimmed + path)
    }

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
