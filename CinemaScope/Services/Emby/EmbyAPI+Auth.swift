import Foundation

// MARK: - Auth

extension EmbyAPI {

    static func fetchUsers(server: EmbyServer) async throws -> [EmbyUser] {
        let url = try endpoint(server, path: "/Users/Public")
        let data = try await get(url: url)
        return try decode([EmbyUser].self, from: data)
    }

    static func authenticate(server: EmbyServer, username: String, password: String) async throws -> EmbyAuthResponse {
        let url = try endpoint(server, path: "/Users/AuthenticateByName")
        let data = try await post(url: url, body: ["Username": username, "Pw": password], token: nil)
        return try decode(EmbyAuthResponse.self, from: data)
    }
}
