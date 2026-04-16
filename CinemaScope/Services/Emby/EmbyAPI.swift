import Foundation

// MARK: - EmbyAPI Errors

enum EmbyError: LocalizedError {
    case invalidURL
    case unauthorized
    case serverError(Int)
    case decodingError(String)
    case noMediaSource

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "Invalid server URL."
        case .unauthorized:         return "Wrong username or password."
        case .serverError(let c):   return "Server error (\(c))."
        case .decodingError(let m): return "Response error: \(m)"
        case .noMediaSource:        return "No playable source found."
        }
    }
}

// MARK: - EmbyAPI

actor EmbyAPI {}
