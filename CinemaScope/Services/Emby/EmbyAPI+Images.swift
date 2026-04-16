import Foundation

// MARK: - Image URLs

extension EmbyAPI {

    static func primaryImageURL(server: EmbyServer, itemId: String, tag: String?, width: Int = 300) -> URL? {
        guard tag != nil else { return nil }
        var comps = try? urlComponents(server, path: "/Items/\(itemId)/Images/Primary")
        comps?.queryItems = [.init(name: "width", value: "\(width)"), .init(name: "quality", value: "90")]
        return comps?.url
    }

    static func thumbImageURL(server: EmbyServer, itemId: String, tag: String?, width: Int = 500) -> URL? {
        guard tag != nil else { return nil }
        var comps = try? urlComponents(server, path: "/Items/\(itemId)/Images/Thumb")
        comps?.queryItems = [.init(name: "width", value: "\(width)"), .init(name: "quality", value: "90")]
        return comps?.url
    }

    static func backdropImageURL(server: EmbyServer, itemId: String, tag: String?, width: Int = 1280) -> URL? {
        guard let tag else { return nil }
        return URL(string: "\(server.url)/Items/\(itemId)/Images/Backdrop?tag=\(tag)&width=\(width)&quality=90")
    }
}
