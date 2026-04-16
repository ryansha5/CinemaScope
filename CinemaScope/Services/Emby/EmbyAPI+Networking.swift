import Foundation

// MARK: - Networking
//
// Core HTTP layer: request construction, auth header, response validation,
// JSON decoding, and URL helpers. Everything in this file stays private to
// the file except the methods that domain extensions call directly.

extension EmbyAPI {

    // Client identification header sent with every request.
    static let clientInfo = "MediaBrowser Client=\"CinemaScope\", Device=\"AppleTV\", DeviceId=\"cinemascope-appletv-1\", Version=\"1.0\""

    // MARK: - HTTP Methods

    static func get(url: URL, token: String? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return data
    }

    static func postJSON(url: URL, body: [String: Any], token: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return data
    }

    static func post(url: URL, body: [String: String], token: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return data
    }

    static func delete(url: URL, token: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response, data: data)
        return data
    }

    // MARK: - System Info (diagnostics)

    static func fetchSystemInfo(server: EmbyServer, token: String) async throws -> EmbySystemInfo {
        let url = try endpoint(server, path: "/System/Info")
        let data = try await get(url: url, token: token)
        return try decode(EmbySystemInfo.self, from: data)
    }

    // MARK: - URL Helpers

    static func endpoint(_ server: EmbyServer, path: String) throws -> URL {
        guard let base = server.baseURL, let url = URL(string: path, relativeTo: base) else { throw EmbyError.invalidURL }
        return url
    }

    static func urlComponents(_ server: EmbyServer, path: String) throws -> URLComponents {
        guard let comps = URLComponents(url: try endpoint(server, path: path), resolvingAgainstBaseURL: true) else { throw EmbyError.invalidURL }
        return comps
    }

    // MARK: - Internal Helpers (private to this file)

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299: return
        case 401: throw EmbyError.unauthorized
        default:
            print("[EmbyAPI] HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            throw EmbyError.serverError(http.statusCode)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw EmbyError.decodingError(error.localizedDescription) }
    }

    private static func authorizationHeader(token: String?) -> String {
        var h = clientInfo
        if let token { h += ", Token=\"\(token)\"" }
        return h
    }
}
