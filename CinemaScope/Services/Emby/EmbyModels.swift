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
    let id:                String
    let name:              String
    let type:              String        // "Movie", "Series", "Episode"
    let productionYear:    Int?
    let imageTags:         ImageTags?
    let backdropImageTags: [String]?
    let overview:          String?
    let runTimeTicks:      Int64?        // 1 tick = 100 nanoseconds
    let userData:          UserData?
    let genres:            [String]?
    let people:            [EmbyPerson]?
    let communityRating:   Double?
    let officialRating:    String?
    let taglines:          [String]?
    let studios:           [EmbyStudio]?
    let parentId:          String?
    let seriesId:          String?       // Series this episode belongs to
    let seriesName:        String?
    let seasonId:          String?
    let seasonName:        String?
    let episodeCount:      Int?
    let childCount:        Int?
    let indexNumber:       Int?       // episode number within season
    let parentIndexNumber: Int?       // season number
    let providerIds:       ProviderIds?

    enum CodingKeys: String, CodingKey {
        case id                = "Id"
        case name              = "Name"
        case type              = "Type"
        case productionYear    = "ProductionYear"
        case imageTags         = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case overview          = "Overview"
        case runTimeTicks      = "RunTimeTicks"
        case userData          = "UserData"
        case genres            = "Genres"
        case people            = "People"
        case communityRating   = "CommunityRating"
        case officialRating    = "OfficialRating"
        case taglines          = "Taglines"
        case studios           = "Studios"
        case parentId          = "ParentId"
        case seriesId          = "SeriesId"
        case seriesName        = "SeriesName"
        case seasonId          = "SeasonId"
        case seasonName        = "SeasonName"
        case episodeCount      = "EpisodeCount"
        case childCount        = "ChildCount"
        case indexNumber       = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case providerIds       = "ProviderIds"
    }

    // Convenience accessor for TMDB ID
    var tmdbId: Int? {
        guard let idStr = providerIds?.tmdb else { return nil }
        return Int(idStr)
    }

    var runtimeMinutes: Int? {
        guard let ticks = runTimeTicks else { return nil }
        return Int(ticks / 600_000_000)
    }

    /// Returns a copy of this item with its `userData` replaced.
    /// Used for local playback-position patching without a server round-trip.
    func withUserData(_ newData: UserData) -> EmbyItem {
        EmbyItem(
            id: id, name: name, type: type, productionYear: productionYear,
            imageTags: imageTags, backdropImageTags: backdropImageTags,
            overview: overview, runTimeTicks: runTimeTicks,
            userData: newData,
            genres: genres, people: people, communityRating: communityRating,
            officialRating: officialRating, taglines: taglines, studios: studios,
            parentId: parentId, seriesId: seriesId, seriesName: seriesName,
            seasonId: seasonId, seasonName: seasonName,
            episodeCount: episodeCount, childCount: childCount,
            indexNumber: indexNumber, parentIndexNumber: parentIndexNumber,
            providerIds: providerIds
        )
    }

    /// Returns true for Christmas / holiday content that should be excluded from recommendations.
    /// Matches on genre "Holiday" or common Christmas keywords in the title.
    var isChristmasContent: Bool {
        let nameLower   = name.lowercased()
        let genresLower = (genres ?? []).map { $0.lowercased() }
        if genresLower.contains("holiday") { return true }
        let terms = ["christmas", "xmas", "santa", "nutcracker", "noel", "jingle"]
        return terms.contains { nameLower.contains($0) }
    }
}

struct ImageTags: Codable, Equatable {
    let primary: String?
    let thumb:   String?   // 16:9 thumbnail — great for TV shows
    let banner:  String?   // wide banner
    let logo:    String?

    enum CodingKeys: String, CodingKey {
        case primary = "Primary"
        case thumb   = "Thumb"
        case banner  = "Banner"
        case logo    = "Logo"
    }
}

struct UserData: Codable, Equatable {
    let playbackPositionTicks: Int64?
    let played:                Bool?
    let isFavorite:            Bool?
    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played                = "Played"
        case isFavorite            = "IsFavorite"
    }
}

// MARK: - Provider IDs

struct ProviderIds: Codable, Equatable {
    let tmdb:   String?
    let imdb:   String?
    let tvdb:   String?

    enum CodingKeys: String, CodingKey {
        case tmdb = "Tmdb"
        case imdb = "Imdb"
        case tvdb = "Tvdb"
    }
}

// MARK: - Person

struct EmbyPerson: Codable, Equatable, Identifiable {
    let id:              String
    let name:            String
    let role:            String?
    let type:            String?    // "Actor", "Director", "Writer", etc.
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id              = "Id"
        case name            = "Name"
        case role            = "Role"
        case type            = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

// MARK: - Studio

struct EmbyStudio: Codable, Equatable {
    let name: String
    let id:   String?
    enum CodingKeys: String, CodingKey { case name = "Name"; case id = "Id" }
}


// MARK: - Genre

struct EmbyGenre: Codable {
    let name: String
    enum CodingKeys: String, CodingKey { case name = "Name" }
}

struct EmbyGenreResponse: Codable {
    let items: [EmbyGenre]
    enum CodingKeys: String, CodingKey { case items = "Items" }
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

// MARK: - System Info (Diagnostics)

struct EmbySystemInfo: Codable {
    let serverName:      String?
    let version:         String?
    let operatingSystem: String?
    let id:              String?

    enum CodingKeys: String, CodingKey {
        case serverName      = "ServerName"
        case version         = "Version"
        case operatingSystem = "OperatingSystem"
        case id              = "Id"
    }
}

// MARK: - Personalized Recommendation

/// A single recommendation card: one movie to watch, paired with the recently-watched
/// movie that seeded it ("Because you watched X").
struct RecommendationItem: Identifiable {
    let id:             String      // == recommendation.id
    let recommendation: EmbyItem
    let becauseOf:      EmbyItem
}

// MARK: - Users Response

struct EmbyUsersResponse: Codable {
    let items: [EmbyUser]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

// MARK: - PlaybackResult
// Returned by EmbyAPI.playbackURL — carries everything the engine needs to
// start playback and send correctly-attributed progress reports to Emby.

struct PlaybackResult {
    /// The URL to hand to AVPlayer (direct-play, direct-stream, or HLS .m3u8)
    let url:           URL
    /// Emby-assigned session ID from PlaybackInfo — must be echoed back in all
    /// progress reports so Emby can match them to the active transcode job.
    let playSessionId: String
    /// Which media source Emby chose — required in progress/stop payloads.
    let mediaSourceId: String
    /// "DirectPlay" | "DirectStream" | "Transcode" — reported to Emby verbatim.
    let playMethod:    String
    /// Sprint 43: The Emby media source selected for this session. Carries
    /// codec/container facts that PlaybackRouter needs to decide between
    /// PlayerLab and AVPlayer. Nil on forced-transcode fallback paths.
    let selectedSource: EmbyMediaSource?
}

// MARK: - Playback Info

struct EmbyPlaybackInfo: Codable {
    let mediaSources:   [EmbyMediaSource]
    let playSessionId:  String?
    enum CodingKeys: String, CodingKey {
        case mediaSources  = "MediaSources"
        case playSessionId = "PlaySessionId"
    }
}

struct EmbyMediaSource: Codable {
    let id:                   String
    let directStreamUrl:      String?
    let transcodingUrl:       String?    // Emby-generated transcode URL
    let transcodingSubProtocol: String?  // "hls", "http"
    let transcodingContainer: String?    // "ts", "mp4"
    let supportsDirectPlay:   Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding:  Bool?
    let requiresOpening:      Bool?
    let requiresClosing:      Bool?
    let mediaStreams:          [EmbyMediaStream]?
    let container:            String?
    let bitrate:              Int?
    let size:                 Int64?
    let videoType:            String?
    let eTag:                 String?

    enum CodingKeys: String, CodingKey {
        case id                     = "Id"
        case directStreamUrl        = "DirectStreamUrl"
        case transcodingUrl         = "TranscodingUrl"
        case transcodingSubProtocol = "TranscodingSubProtocol"
        case transcodingContainer   = "TranscodingContainer"
        case supportsDirectPlay     = "SupportsDirectPlay"
        case supportsDirectStream   = "SupportsDirectStream"
        case supportsTranscoding    = "SupportsTranscoding"
        case requiresOpening        = "RequiresOpening"
        case requiresClosing        = "RequiresClosing"
        case mediaStreams            = "MediaStreams"
        case container              = "Container"
        case bitrate                = "Bitrate"
        case size                   = "Size"
        case videoType              = "VideoType"
        case eTag                   = "ETag"
    }

    // Convenience
    var videoStream: EmbyMediaStream? {
        mediaStreams?.first { $0.type.lowercased() == "video" }
    }
    var audioStreams: [EmbyMediaStream] {
        mediaStreams?.filter { $0.type.lowercased() == "audio" } ?? []
    }
    var subtitleStreams: [EmbyMediaStream] {
        mediaStreams?.filter { $0.type.lowercased() == "subtitle" } ?? []
    }
}

struct EmbyMediaStream: Codable {
    let index:             Int?      // Emby's 0-based stream index — used for AudioStreamIndex / SubtitleStreamIndex params
    let type:              String    // "Video", "Audio", "Subtitle"
    let codec:             String?
    let width:             Int?
    let height:            Int?
    let displayTitle:      String?
    let bitrate:           Int?      // stream bitrate in bps
    let bitDepth:          Int?      // 8, 10, 12-bit
    let videoRange:        String?   // "SDR", "HDR", "HDR10", "DolbyVision"
    let videoRangeType:    String?   // "HDR10", "HLG", "DOVIWithHDR10", etc.
    let colorSpace:        String?
    let profile:           String?   // "High", "Main 10", "DV Profile 5", etc.
    let level:             Double?
    let frameRate:         Double?
    let averageFrameRate:  Double?
    let channels:          Int?      // audio channels
    let channelLayout:     String?   // "stereo", "5.1", "7.1 Atmos"
    let sampleRate:        Int?
    let language:          String?
    let title:             String?
    let isDefault:         Bool?
    let isForced:          Bool?
    let supportsExternalStream: Bool?

    enum CodingKeys: String, CodingKey {
        case index             = "Index"
        case type              = "Type"
        case codec             = "Codec"
        case width             = "Width"
        case height            = "Height"
        case displayTitle      = "DisplayTitle"
        case bitrate           = "BitRate"
        case bitDepth          = "BitDepth"
        case videoRange        = "VideoRange"
        case videoRangeType    = "VideoRangeType"
        case colorSpace        = "ColorSpace"
        case profile           = "Profile"
        case level             = "Level"
        case frameRate         = "FrameRate"
        case averageFrameRate  = "AverageFrameRate"
        case channels          = "Channels"
        case channelLayout     = "ChannelLayout"
        case sampleRate        = "SampleRate"
        case language          = "Language"
        case title             = "Title"
        case isDefault         = "IsDefault"
        case isForced          = "IsForced"
        case supportsExternalStream = "SupportsExternalStream"
    }

    // Human-readable resolution label
    var resolutionLabel: String? {
        guard let w = width, let h = height else { return nil }
        switch h {
        case 2160...: return "4K"
        case 1440...: return "1440p"
        case 1080...: return "1080p"
        case 720...:  return "720p"
        case 480...:  return "480p"
        default:      return "\(h)p"
        }
    }

    // HDR badge
    var hdrLabel: String? {
        switch (videoRangeType ?? "").lowercased() {
        case let s where s.contains("dovi"):   return "Dolby Vision"
        case let s where s.contains("hdr10+"): return "HDR10+"
        case let s where s.contains("hdr10"):  return "HDR10"
        case let s where s.contains("hlg"):    return "HLG"
        case "hdr":                             return "HDR"
        default:
            switch (videoRange ?? "").lowercased() {
            case "hdr": return "HDR"
            default:    return nil
            }
        }
    }

    // Audio label
    var audioLabel: String? {
        guard type.lowercased() == "audio" else { return nil }
        var parts: [String] = []
        if let codec = codec?.uppercased() { parts.append(codec) }
        if let layout = channelLayout { parts.append(layout) }
        return parts.isEmpty ? displayTitle : parts.joined(separator: " ")
    }
}
