import Foundation

// MARK: - RibbonType
// Defines every possible ribbon the user can place on the home screen.

enum RibbonType: Codable, Equatable, Hashable {
    case continueWatching
    case nextUp                                       // next unwatched episode per in-progress series
    case recentMovies
    case recentTV
    case movies
    case tvShows
    case collections
    case playlists
    case favorites                                    // user-favorited movies + series
    case genre(name: String, itemType: String)       // e.g. genre("Action", "Movie")
    case recommended                                  // driven by Emby play history

    // Human-readable label shown in settings
    var displayName: String {
        switch self {
        case .continueWatching:          return "Continue Watching"
        case .nextUp:                    return "Up Next"
        case .recentMovies:              return "Recently Added Movies"
        case .recentTV:                  return "Recently Added TV"
        case .movies:                    return "Movies"
        case .tvShows:                   return "TV Shows"
        case .collections:               return "Collections"
        case .playlists:                 return "Playlists"
        case .favorites:                 return "My Favorites"
        case .genre(let name, _):        return name
        case .recommended:               return "Recommended For You"
        }
    }

    // Which card shape best suits this ribbon's content
    var preferredCardSize: CardSize {
        switch self {
        case .continueWatching:  return .wide
        case .nextUp:            return .wide
        case .recentTV:          return .thumb
        case .tvShows:           return .thumb
        case .genre(_, let t):   return t == "Series" ? .thumb : .poster
        default:                 return .poster
        }
    }

    var icon: String {
        switch self {
        case .continueWatching:  return "play.circle.fill"
        case .nextUp:            return "tv.badge.wifi"
        case .recentMovies:      return "film"
        case .recentTV:          return "tv"
        case .movies:            return "film.stack"
        case .tvShows:           return "tv.and.mediabox"
        case .collections:       return "rectangle.stack.fill"
        case .playlists:         return "music.note.list"
        case .favorites:         return "heart.fill"
        case .genre:             return "tag.fill"
        case .recommended:       return "star.fill"
        }
    }

    // Stable ID for Identifiable conformance
    var id: String {
        switch self {
        case .continueWatching:              return "continueWatching"
        case .nextUp:                        return "nextUp"
        case .recentMovies:                  return "recentMovies"
        case .recentTV:                      return "recentTV"
        case .movies:                        return "movies"
        case .tvShows:                       return "tvShows"
        case .collections:                   return "collections"
        case .playlists:                     return "playlists"
        case .favorites:                     return "favorites"
        case .genre(let name, let type):     return "genre_\(type)_\(name)"
        case .recommended:                   return "recommended"
        }
    }
}

// MARK: - HomeRibbon

struct HomeRibbon: Codable, Equatable, Identifiable {
    let id:      String        // stable UUID string
    var type:    RibbonType
    var enabled: Bool

    init(type: RibbonType, enabled: Bool = true) {
        self.id      = UUID().uuidString
        self.type    = type
        self.enabled = enabled
    }
}

// MARK: - Default ribbon layout

extension HomeRibbon {
    static var defaults: [HomeRibbon] {[
        HomeRibbon(type: .continueWatching),
        HomeRibbon(type: .recommended),
        HomeRibbon(type: .recentMovies),
        HomeRibbon(type: .recentTV),
        HomeRibbon(type: .favorites),
        HomeRibbon(type: .movies),
        HomeRibbon(type: .tvShows),
        HomeRibbon(type: .collections),
    ]}
}
