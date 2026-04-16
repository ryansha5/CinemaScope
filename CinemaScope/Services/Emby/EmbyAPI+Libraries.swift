import Foundation

// MARK: - Libraries

private struct EmbyItemsResponse_Library: Codable {
    let items: [EmbyLibrary]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

extension EmbyAPI {

    static func fetchLibraries(server: EmbyServer, userId: String, token: String) async throws -> [EmbyLibrary] {
        let url = try endpoint(server, path: "/Users/\(userId)/Views")
        let data = try await get(url: url, token: token)
        return try decode(EmbyItemsResponse_Library.self, from: data).items
    }
}
