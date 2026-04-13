import Foundation

// MARK: - Server

struct EmbyServer: Codable {
    let url: String  // e.g. "http://192.168.1.10:8096" or "https://media.example.com"

    var baseURL: URL? { URL(string: url) }
}

// MARK: - Auth

struct EmbyAuthResponse: Codable {
    let accessToken: String
    let user: EmbyUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user        = "User"
    }
}

// MARK: - User

struct EmbyUser: Codable, Identifiable {
    let id:   String
    let name: String
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id              = "Id"
        case name            = "Name"
        case primaryImageTag = "PrimaryImageTag"
    }
}

// MARK: - Library

struct EmbyLibrary: Codable, Identifiable {
    let id:           String
    let name:         String
    let collectionType: String?  // "movies", "tvshows", etc.

    enum CodingKeys: String, CodingKey {
        case id             = "Id"
        case name           = "Name"
        case collectionType = "CollectionType"
    }
}

// MARK: - Media Item

struct EmbyItem: Codable, Identifiable, Equatable {
    let id:              String
    let name:            String
    let type:            String        // "Movie", "Series", "Episode"
    let productionYear:  Int?
    let imageTags:       ImageTags?
    let backdropImageTags: [String]?
    let overview:        String?
    let runTimeTicks:    Int64?        // 1 tick = 100 nanoseconds
    let userData:        UserData?

    enum CodingKeys: String, CodingKey {
        case id              = "Id"
        case name            = "Name"
        case type            = "Type"
        case productionYear  = "ProductionYear"
        case imageTags       = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case overview        = "Overview"
        case runTimeTicks    = "RunTimeTicks"
        case userData        = "UserData"
    }

    var runtimeMinutes: Int? {
        guard let ticks = runTimeTicks else { return nil }
        return Int(ticks / 600_000_000)
    }
}

struct ImageTags: Codable, Equatable {
    let primary: String?
    enum CodingKeys: String, CodingKey { case primary = "Primary" }
}

struct UserData: Codable, Equatable {
    let playbackPositionTicks: Int64?
    let played:                Bool?
    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played                = "Played"
    }
}

// MARK: - Items Response

struct EmbyItemsResponse: Codable {
    let items:      [EmbyItem]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items            = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

// MARK: - Users Response

struct EmbyUsersResponse: Codable {
    let items: [EmbyUser]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

// MARK: - Playback Info

struct EmbyPlaybackInfo: Codable {
    let mediaSources: [EmbyMediaSource]
    enum CodingKeys: String, CodingKey { case mediaSources = "MediaSources" }
}

struct EmbyMediaSource: Codable {
    let id:              String
    let directStreamUrl: String?
    let supportsDirectStream: Bool?
    let mediaStreams:    [EmbyMediaStream]?
    let container:      String?   // "mkv", "mp4", "avi", etc.

    enum CodingKeys: String, CodingKey {
        case id                  = "Id"
        case directStreamUrl     = "DirectStreamUrl"
        case supportsDirectStream = "SupportsDirectStream"
        case mediaStreams         = "MediaStreams"
        case container           = "Container"
    }
}

struct EmbyMediaStream: Codable {
    let type:          String   // "Video", "Audio", "Subtitle"
    let codec:         String?
    let width:         Int?
    let height:        Int?
    let displayTitle:  String?

    enum CodingKeys: String, CodingKey {
        case type         = "Type"
        case codec        = "Codec"
        case width        = "Width"
        case height       = "Height"
        case displayTitle = "DisplayTitle"
    }
}
