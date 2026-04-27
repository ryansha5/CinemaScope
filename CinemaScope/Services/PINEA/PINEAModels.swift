import Foundation

// MARK: - PINEAUser

struct PINEAUser: Codable, Identifiable {
    let id:       String
    let username: String
    let email:    String
}

// MARK: - Auth responses

struct PINEAAuthResponse: Codable {
    let token: String
    let user:  PINEAUser
}

// MARK: - Library connection (Sprint 2)

/// Response shape for GET /api/me/library-connection
/// `connected` is always present; remaining fields only when a connection exists.
struct PINEALibraryStatus: Codable {
    let connected:  Bool
    let serverURL:  String?
    let embyUserId: String?

    // Explicit keys match the PINEA backend JSON contract.
    // backend sends camelCase — Swift default decoder handles this automatically,
    // but explicit mapping makes the contract visible and refactor-safe.
    enum CodingKeys: String, CodingKey {
        case connected
        case serverURL  = "server_url"
        case embyUserId = "emby_user_id"
    }
}

/// Request body for POST /api/me/library-connection
struct PINEALibraryConnectionRequest: Encodable {
    let serverURL:  String
    let embyUserId: String
    let embyToken:  String

    enum CodingKeys: String, CodingKey {
        case serverURL  = "server_url"
        case embyUserId = "emby_user_id"
        case embyToken  = "emby_token"
    }
}

// MARK: - Library access mode (Sprint 4)

/// Describes the app's current ability to access library content.
/// Derived from PINEAEnvironment's published flags — never stored directly.
///
/// Transitions:
///   unauthenticated / init               → (not evaluated — routing gates on isAuthenticated)
///   startup checks running               → .checking
///   authenticated, no connection/snapshot → .none
///   authenticated, snapshot only         → .snapshot
///   authenticated + live connection      → .liveReady
///
/// Playback is always direct-to-Emby regardless of this mode.
/// This mode is used for metadata / state preparation only.
enum PINEALibraryAccessMode: Equatable {
    /// Startup or background checks are in progress; mode not yet determined.
    case checking
    /// Authenticated but no library connection and no usable backend snapshot.
    case none
    /// Backend snapshot exists; metadata available but no live Emby connection confirmed.
    case snapshot
    /// Live Emby connection confirmed and accessible — app can proceed with full confidence.
    case liveReady
}

// MARK: - Library snapshot (Sprint 3)

/// Response from GET /api/me/library/status
struct PINEALibrarySnapshotStatus: Codable {
    let hasSnapshot:  Bool
    let itemCount:    Int?
    let lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case hasSnapshot  = "has_snapshot"
        case itemCount    = "item_count"
        case lastSyncedAt = "last_synced_at"
    }
}

/// Lightweight metadata item from GET /api/me/library
/// Intentionally minimal — playback goes through Emby directly,
/// not through this struct.
struct PINEALibraryItem: Codable, Identifiable, Equatable {
    let id:           String
    let title:        String
    let type:         String        // "Movie", "Series", "Episode"
    let year:         Int?
    let genres:       [String]?
    let thumbnailURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, type, year, genres
        case thumbnailURL = "thumbnail_url"
    }
}

/// Envelope for GET /api/me/library
struct PINEALibraryResponse: Codable {
    let items: [PINEALibraryItem]
}

/// Response from POST /api/me/library/sync
struct PINEASyncResponse: Codable {
    let syncedAt:  Date?
    let itemCount: Int

    enum CodingKeys: String, CodingKey {
        case syncedAt  = "synced_at"
        case itemCount = "item_count"
    }
}

// MARK: - Session (Sprint 5)

/// Playback state reported by the backend session endpoint.
/// PINEA reads this for awareness only — playback remains direct-to-Emby.
enum PINEASessionPlaybackState: String, Codable, Equatable {
    case idle       = "idle"
    case playing    = "playing"
    case paused     = "paused"
    case buffering  = "buffering"
    case stopped    = "stopped"
}

/// Lightweight summary of the item currently (or last) associated with a session.
struct PINEASessionMovieSummary: Codable, Equatable {
    let id:           String
    let title:        String
    let year:         Int?
    let thumbnailURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, year
        case thumbnailURL = "thumbnail_url"
    }
}

/// Response from GET /api/me/session/current.
/// `nil` fields indicate the session exists but the value is unavailable.
struct PINEASession: Codable, Identifiable, Equatable {
    let id:             String
    let state:          PINEASessionPlaybackState
    let deviceName:     String?
    let positionTicks:  Int64?
    let durationTicks:  Int64?
    let updatedAt:      Date?
    let movie:          PINEASessionMovieSummary?

    enum CodingKeys: String, CodingKey {
        case id, state, movie
        case deviceName    = "device_name"
        case positionTicks = "position_ticks"
        case durationTicks = "duration_ticks"
        case updatedAt     = "updated_at"
    }

    /// Convenience: progress fraction 0–1, or nil if position/duration unavailable.
    var progressFraction: Double? {
        guard let pos = positionTicks, let dur = durationTicks, dur > 0 else { return nil }
        return min(Double(pos) / Double(dur), 1.0)
    }
}

/// Envelope for GET /api/me/session/current.
/// `session` is nil when no active session exists for the user.
struct PINEASessionResponse: Codable {
    let session: PINEASession?
}

// MARK: - Error

struct PINEAServiceError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static let invalidURL      = PINEAServiceError(message: "Invalid backend URL. Check your configuration.")
    static let invalidResponse = PINEAServiceError(message: "Unexpected response from server.")
}
