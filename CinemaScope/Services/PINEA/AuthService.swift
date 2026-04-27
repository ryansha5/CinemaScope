import Foundation

// MARK: - AuthService
//
// All calls to the PINEA platform auth API go through here.
// Routes are defined as constants below — swap them when the backend
// promotes from the transitional dev-auth scaffold to production auth.

actor AuthService {

    static let shared = AuthService()
    private init() {}

    // ── Route constants ──────────────────────────────────────────────────────
    // Transitional note: if backend still uses /api/dev/*, change these two
    // strings and nothing else in the UI needs to change.
    private enum Route {
        static let login    = "/api/auth/login"
        static let register = "/api/auth/register"
        static let me       = "/api/me"
    }

    // MARK: - Public API

    func login(baseURL: String, email: String, password: String) async throws -> PINEAAuthResponse {
        let url  = try endpoint(baseURL, Route.login)
        let body = ["email": email, "password": password]
        return try await post(url: url, body: body)
    }

    func register(
        baseURL: String,
        username: String,
        email: String,
        password: String
    ) async throws -> PINEAAuthResponse {
        let url  = try endpoint(baseURL, Route.register)
        let body = ["username": username, "email": email, "password": password]
        return try await post(url: url, body: body)
    }

    func fetchMe(baseURL: String, token: String) async throws -> PINEAUser {
        let url = try endpoint(baseURL, Route.me)
        return try await get(url: url, token: token)
    }

    // MARK: - Private networking

    private func endpoint(_ base: String, _ path: String) throws -> URL {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: trimmed + path) else { throw PINEAServiceError.invalidURL }
        return url
    }

    private func post<T: Decodable>(url: URL, body: [String: String], token: String? = nil) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response, data: data)
        return try decoded(T.self, from: data)
    }

    private func get<T: Decodable>(url: URL, token: String) async throws -> T {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validateHTTP(response, data: data)
        return try decoded(T.self, from: data)
    }

    private func validateHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw PINEAServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Try to surface a server-provided message
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["message"]
                   ?? (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                   ?? "Server returned \(http.statusCode)"
            throw PINEAServiceError(message: msg)
        }
    }

    private func decoded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw PINEAServiceError(message: "Could not parse server response.")
        }
    }
}
