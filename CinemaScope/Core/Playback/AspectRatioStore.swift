import Foundation

// MARK: - AspectRatioOverride

/// A manually-specified aspect ratio that overrides auto-detection for a specific title.
/// Stored per item so the user's correction is never forgotten.
enum AspectRatioOverride: String, CaseIterable, Identifiable {

    case auto    // no override — use detection pipeline
    case scope   // force 2.39:1
    case flat    // force 1.85:1
    case hdtv    // force 16:9 = 1.778
    case academy // force 4:3 = 1.333

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:    return "Auto"
        case .scope:   return "Scope (2.39)"
        case .flat:    return "Flat (1.85)"
        case .hdtv:    return "16:9"
        case .academy: return "4:3"
        }
    }

    /// Short label for the OSD badge (when an override is active).
    var badgeLabel: String? {
        switch self {
        case .auto:    return nil
        case .scope:   return "2.39 override"
        case .flat:    return "1.85 override"
        case .hdtv:    return "16:9 override"
        case .academy: return "4:3 override"
        }
    }

    /// The fixed ratio to use for geometry, or nil for auto-detect.
    var fixedRatio: Double? {
        switch self {
        case .auto:    return nil
        case .scope:   return 2.39
        case .flat:    return 1.85
        case .hdtv:    return 16.0 / 9.0
        case .academy: return 4.0 / 3.0
        }
    }

    /// The corresponding bucket, used to update the OSD badge after an override.
    var bucket: AspectBucket? {
        switch self {
        case .auto:    return nil
        case .scope:   return .scope
        case .flat:    return .flat
        case .hdtv:    return .hdtv
        case .academy: return .academy
        }
    }
}

// MARK: - AspectRatioStore

/// Persists manual aspect ratio overrides per item across sessions.
///
/// Key format: "server:{serverURL}:item:{itemId}"
/// Storage: UserDefaults JSON dictionary (lightweight, no Core Data needed).
final class AspectRatioStore {

    static let shared = AspectRatioStore()
    private init() {}

    private let defaultsKey = "aspectRatioOverrides_v1"

    // MARK: - Public API

    /// Returns the stored override for a given (server, item) pair, or .auto if none.
    func override(serverURL: String, itemId: String) -> AspectRatioOverride {
        let key = storeKey(serverURL: serverURL, itemId: itemId)
        guard let dict = loadDict(),
              let raw  = dict[key],
              let val  = AspectRatioOverride(rawValue: raw) else {
            return .auto
        }
        return val
    }

    /// Persists a manual override.  Passing .auto removes any stored entry.
    func setOverride(_ override: AspectRatioOverride, serverURL: String, itemId: String) {
        let key = storeKey(serverURL: serverURL, itemId: itemId)
        var dict = loadDict() ?? [:]
        if override == .auto {
            dict.removeValue(forKey: key)   // .auto = no entry needed
        } else {
            dict[key] = override.rawValue
        }
        saveDict(dict)
    }

    // MARK: - Private helpers

    private func storeKey(serverURL: String, itemId: String) -> String {
        "server:\(serverURL):item:\(itemId)"
    }

    private func loadDict() -> [String: String]? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return dict
    }

    private func saveDict(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
