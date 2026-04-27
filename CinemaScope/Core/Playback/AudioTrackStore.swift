import Foundation

// MARK: - AvailableAudioTrack

/// Represents one audio track available for a piece of content.
/// Built from Emby's MediaStream metadata — everything the future
/// audio track picker UI will need to present a labelled list.
struct AvailableAudioTrack: Identifiable, Equatable {
    let streamIndex:   Int       // Emby MediaStream.Index — used in AudioStreamIndex param
    let language:      String?   // ISO 639 language code, e.g. "eng", "ger"
    let displayTitle:  String?   // Emby's human-readable label, e.g. "English DTS 5.1"
    let title:         String?   // Track-level title tag (may differ from displayTitle)
    let codec:         String?   // e.g. "ac3", "truehd", "aac"
    let channels:      Int?      // channel count, e.g. 2 (stereo), 6 (5.1), 8 (7.1)
    let channelLayout: String?   // e.g. "stereo", "5.1", "7.1 Atmos"
    let isDefault:     Bool
    let isForced:      Bool

    var id: Int { streamIndex }

    // MARK: - Human-readable label (for future OSD picker)

    /// Short label for display in a track selector.
    /// Priority: displayTitle → language + codec + channels → codec → index
    var label: String {
        if let dt = displayTitle, !dt.isEmpty { return dt }
        var parts: [String] = []
        if let lang = language,   !lang.isEmpty { parts.append(lang.uppercased()) }
        if let c    = codec,      !c.isEmpty    { parts.append(c.uppercased()) }
        if let ch   = channels                  { parts.append("\(ch)ch") }
        return parts.isEmpty ? "Track \(streamIndex)" : parts.joined(separator: " ")
    }

    /// Longer label showing channel layout where known.
    var detailLabel: String {
        var s = label
        if let layout = channelLayout, !layout.isEmpty,
           !(displayTitle ?? "").lowercased().contains(layout.lowercased()) {
            s += " (\(layout))"
        }
        return s
    }
}

// MARK: - AvailableAudioTrack + EmbyMediaStream factory

extension AvailableAudioTrack {
    /// Returns nil if the stream has no index (shouldn't happen but be safe).
    static func from(_ stream: EmbyMediaStream) -> AvailableAudioTrack? {
        guard let idx = stream.index else { return nil }
        return AvailableAudioTrack(
            streamIndex:   idx,
            language:      stream.language,
            displayTitle:  stream.displayTitle,
            title:         stream.title,
            codec:         stream.codec,
            channels:      stream.channels,
            channelLayout: stream.channelLayout,
            isDefault:     stream.isDefault ?? false,
            isForced:      stream.isForced  ?? false
        )
    }
}

// MARK: - AudioTrackSelection

/// The per-item audio track preference.
///
/// `.automatic` — the app chose the best compatible stream (current behaviour).
/// `.explicit`  — the user explicitly picked a stream; this takes priority over
///                both the automatic selection and any Emby server preference.
enum AudioTrackSelection: Equatable {

    case automatic
    case explicit(streamIndex: Int)

    // MARK: Convenience

    var streamIndex: Int? {
        if case .explicit(let idx) = self { return idx }
        return nil
    }

    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .automatic:               return "Auto"
        case .explicit(let idx):       return "Track \(idx)"
        }
    }
}

// MARK: - AudioTrackStore

/// Persists explicit per-item audio track overrides across sessions.
///
/// When the user picks a track from the OSD picker, call `setOverride()`.
/// On the next playback of the same item, `override()` returns the stored
/// index so it can be passed as `AudioStreamIndex` to PlaybackInfo.
///
/// Key format: "server:{serverURL}:item:{itemId}"
/// Storage: UserDefaults Int dictionary (stream index, no entry = automatic).
///
/// FUTURE preference policy:
///   • `.preferOriginalLanguage` — pick highest-channel AC3/EAC3 regardless of lang
///   • `.preferEnglish`          — bias toward lang="eng" among compatible streams
///   • `.preferHighestChannel`   — current automatic behaviour (codec → channels)
final class AudioTrackStore {

    static let shared = AudioTrackStore()
    private init() {}

    private let defaultsKey = "audioTrackOverrides_v1"

    // MARK: - Public API

    /// Returns the stored override for a given (server, item) pair, or .automatic if none.
    func override(serverURL: String, itemId: String) -> AudioTrackSelection {
        let key = storeKey(serverURL: serverURL, itemId: itemId)
        guard let dict  = loadDict(),
              let index = dict[key] else { return .automatic }
        return .explicit(streamIndex: index)
    }

    /// Persists a manual override. Passing `.automatic` removes any stored entry.
    func setOverride(
        _ selection: AudioTrackSelection,
        serverURL:   String,
        itemId:      String
    ) {
        let key  = storeKey(serverURL: serverURL, itemId: itemId)
        var dict = loadDict() ?? [:]
        switch selection {
        case .automatic:
            dict.removeValue(forKey: key)
        case .explicit(let idx):
            dict[key] = idx
        }
        saveDict(dict)
        print("[AudioTrackStore] \(selection.isAutomatic ? "cleared" : "saved index=\(selection.streamIndex!)") for item=\(itemId)")
    }

    // MARK: - Private helpers

    private func storeKey(serverURL: String, itemId: String) -> String {
        "server:\(serverURL):item:\(itemId)"
    }

    private func loadDict() -> [String: Int]? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let dict = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return nil }
        return dict
    }

    private func saveDict(_ dict: [String: Int]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
