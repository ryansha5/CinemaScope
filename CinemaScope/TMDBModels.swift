import Foundation

// MARK: - TMDB Models

struct TMDBMovieDetail: Codable {
    let id:             Int
    let title:          String
    let overview:       String?
    let tagline:        String?
    let releaseDate:    String?
    let runtime:        Int?
    let voteAverage:    Double?
    let posterPath:     String?
    let backdropPath:   String?
    let genres:         [TMDBGenre]?
    let credits:        TMDBCredits?
    let videos:         TMDBVideoResults?
    let belongsToCollection: TMDBCollection?
    let productionCompanies: [TMDBCompany]?
    let keywords:       TMDBKeywordResults?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, tagline, runtime, genres, credits, videos, keywords
        case releaseDate             = "release_date"
        case voteAverage             = "vote_average"
        case posterPath              = "poster_path"
        case backdropPath            = "backdrop_path"
        case belongsToCollection     = "belongs_to_collection"
        case productionCompanies     = "production_companies"
    }
}

struct TMDBTVDetail: Codable {
    let id:              Int
    let name:            String
    let overview:        String?
    let tagline:         String?
    let firstAirDate:    String?
    let voteAverage:     Double?
    let posterPath:      String?
    let backdropPath:    String?
    let genres:          [TMDBGenre]?
    let credits:         TMDBCredits?
    let videos:          TMDBVideoResults?
    let numberOfSeasons: Int?
    let numberOfEpisodes: Int?
    let productionCompanies: [TMDBCompany]?
    let keywords:        TMDBTVKeywordResults?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, tagline, genres, credits, videos, keywords
        case firstAirDate        = "first_air_date"
        case voteAverage         = "vote_average"
        case posterPath          = "poster_path"
        case backdropPath        = "backdrop_path"
        case numberOfSeasons     = "number_of_seasons"
        case numberOfEpisodes    = "number_of_episodes"
        case productionCompanies = "production_companies"
    }
}

struct TMDBGenre: Codable {
    let id:   Int
    let name: String
}

struct TMDBCredits: Codable {
    let cast: [TMDBCastMember]?
    let crew: [TMDBCrewMember]?
}

struct TMDBCastMember: Codable, Identifiable {
    let id:          Int
    let name:        String
    let character:   String?
    let profilePath: String?
    let order:       Int?

    enum CodingKeys: String, CodingKey {
        case id, name, character, order
        case profilePath = "profile_path"
    }
}

struct TMDBCrewMember: Codable, Identifiable {
    let id:          Int
    let name:        String
    let job:         String?
    let department:  String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, job, department
        case profilePath = "profile_path"
    }
}

struct TMDBVideoResults: Codable {
    let results: [TMDBVideo]?
}

struct TMDBVideo: Codable, Identifiable {
    let id:       String
    let key:      String      // YouTube video key
    let name:     String
    let site:     String      // "YouTube"
    let type:     String      // "Trailer", "Teaser", "Clip", etc.
    let official: Bool?
}

struct TMDBCollection: Codable {
    let id:           Int
    let name:         String
    let posterPath:   String?
    let backdropPath: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case posterPath   = "poster_path"
        case backdropPath = "backdrop_path"
    }
}

struct TMDBCompany: Codable {
    let id:   Int
    let name: String
}

struct TMDBKeywordResults: Codable {
    let keywords: [TMDBKeyword]?
}

struct TMDBTVKeywordResults: Codable {
    let results: [TMDBKeyword]?
}

struct TMDBKeyword: Codable {
    let id:   Int
    let name: String
}

struct TMDBSearchResults: Codable {
    let results: [TMDBSearchResult]?
}

struct TMDBSearchResult: Codable {
    let id:           Int
    let mediaType:    String?
    let title:        String?   // movies
    let name:         String?   // TV
    let releaseDate:  String?
    let firstAirDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name
        case mediaType   = "media_type"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
    }
}

// MARK: - Unified TMDB metadata (merged from movie or TV response)

struct TMDBMetadata {
    let tmdbId:          Int
    let overview:        String?
    let tagline:         String?
    let voteAverage:     Double?
    let posterPath:      String?
    let backdropPath:    String?
    let genres:          [String]
    let cast:            [TMDBCastMember]
    let directors:       [TMDBCrewMember]
    let writers:         [TMDBCrewMember]
    let trailer:         TMDBVideo?        // best official trailer
    let collection:      TMDBCollection?
    let studios:         [String]
    let keywords:        [String]

    // Full image URLs
    static let posterBase   = "https://image.tmdb.org/t/p/w500"
    static let backdropBase = "https://image.tmdb.org/t/p/w1280"
    static let profileBase  = "https://image.tmdb.org/t/p/w185"

    func posterURL()   -> URL? { posterPath.flatMap   { URL(string: Self.posterBase   + $0) } }
    func backdropURL() -> URL? { backdropPath.flatMap  { URL(string: Self.backdropBase + $0) } }

    static func profileURL(path: String?) -> URL? {
        path.flatMap { URL(string: profileBase + $0) }
    }

    // Pick best trailer: official YouTube trailer first, then any teaser
    static func bestTrailer(from videos: [TMDBVideo]?) -> TMDBVideo? {
        guard let videos else { return nil }
        let youtube = videos.filter { $0.site == "YouTube" }
        return youtube.first(where: { $0.type == "Trailer" && $0.official == true })
            ?? youtube.first(where: { $0.type == "Trailer" })
            ?? youtube.first(where: { $0.type == "Teaser" })
    }

    static func from(movie: TMDBMovieDetail) -> TMDBMetadata {
        TMDBMetadata(
            tmdbId:      movie.id,
            overview:    movie.overview,
            tagline:     movie.tagline,
            voteAverage: movie.voteAverage,
            posterPath:  movie.posterPath,
            backdropPath: movie.backdropPath,
            genres:      movie.genres?.map(\.name) ?? [],
            cast:        movie.credits?.cast ?? [],
            directors:   movie.credits?.crew?.filter { $0.job == "Director" } ?? [],
            writers:     movie.credits?.crew?.filter { $0.department == "Writing" } ?? [],
            trailer:     bestTrailer(from: movie.videos?.results),
            collection:  movie.belongsToCollection,
            studios:     movie.productionCompanies?.map(\.name) ?? [],
            keywords:    movie.keywords?.keywords?.map(\.name) ?? []
        )
    }

    static func from(tv: TMDBTVDetail) -> TMDBMetadata {
        TMDBMetadata(
            tmdbId:      tv.id,
            overview:    tv.overview,
            tagline:     tv.tagline,
            voteAverage: tv.voteAverage,
            posterPath:  tv.posterPath,
            backdropPath: tv.backdropPath,
            genres:      tv.genres?.map(\.name) ?? [],
            cast:        tv.credits?.cast ?? [],
            directors:   tv.credits?.crew?.filter { $0.job == "Director" } ?? [],
            writers:     tv.credits?.crew?.filter { $0.department == "Writing" } ?? [],
            trailer:     bestTrailer(from: tv.videos?.results),
            collection:  nil,
            studios:     tv.productionCompanies?.map(\.name) ?? [],
            keywords:    tv.keywords?.results?.map(\.name) ?? []
        )
    }
}
