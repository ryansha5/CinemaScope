import Foundation
import Combine

// MARK: - PlaybackEngineMode
//
// Controls which playback engine handles media in HomeView.
//
//   avPlayerOnly       — bypass PlayerLab entirely; use Emby's DirectPlay /
//                        TranscodingUrl path only. Use this to restore a known-
//                        good baseline or diagnose PlayerLab regressions.
//
//   playerLabPreferred — two-stage routing: PlayerLab handles compatible files
//                        (raw-stream MKV/MP4 meeting the confidence threshold);
//                        AVPlayer handles everything else. This is the normal
//                        production mode once PlayerLab is stable.
//
//   playerLabOnlyDebug — always route to PlayerLab, never fall back. Use only
//                        during active PlayerLab development; expected to fail
//                        on files PlayerLab does not yet support.

enum PlaybackEngineMode: String, CaseIterable, Codable {
    case avPlayerOnly        = "avPlayerOnly"
    case playerLabPreferred  = "playerLabPreferred"
    case playerLabOnlyDebug  = "playerLabOnlyDebug"

    var displayLabel: String {
        switch self {
        case .avPlayerOnly:       return "AVPlayer Only"
        case .playerLabPreferred: return "PlayerLab (Preferred)"
        case .playerLabOnlyDebug: return "PlayerLab Only (Debug)"
        }
    }

    var shortLabel: String {
        switch self {
        case .avPlayerOnly:       return "AVPlayer"
        case .playerLabPreferred: return "PlayerLab + AVPlayer"
        case .playerLabOnlyDebug: return "PlayerLab (debug)"
        }
    }

    /// True when PlayerLab should be consulted at all for a given play() call.
    var playerLabEnabled: Bool {
        switch self {
        case .avPlayerOnly:       return false
        case .playerLabPreferred: return true
        case .playerLabOnlyDebug: return true
        }
    }
}

// MARK: - AppSettings

final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - Scope UI

    @Published var scopeUIEnabled: Bool {
        didSet { UserDefaults.standard.set(scopeUIEnabled, forKey: "scopeUIEnabled") }
    }

    // MARK: - Color Mode

    @Published var colorMode: ColorMode {
        didSet { UserDefaults.standard.set(colorMode.rawValue, forKey: "colorMode") }
    }

    // MARK: - Home Screen Ribbons

    @Published var homeRibbons: [HomeRibbon] {
        didSet { saveRibbons() }
    }

    // MARK: - Recent Searches

    @Published var recentSearches: [String] {
        didSet { UserDefaults.standard.set(recentSearches, forKey: "recentSearches") }
    }

    // MARK: - Playback defaults

    /// Auto-play the next episode after a countdown when an episode finishes.
    @Published var autoplayNextEpisode: Bool {
        didSet { UserDefaults.standard.set(autoplayNextEpisode, forKey: "autoplayNextEpisode") }
    }

    /// Show subtitles by default when a subtitle track is available.
    @Published var subtitlesEnabled: Bool {
        didSet { UserDefaults.standard.set(subtitlesEnabled, forKey: "subtitlesEnabled") }
    }

    /// Preferred audio language code (e.g. "en", "fr"). Empty = server default.
    @Published var preferredAudioLanguage: String {
        didSet { UserDefaults.standard.set(preferredAudioLanguage, forKey: "preferredAudioLanguage") }
    }

    // MARK: - Startup

    /// The tab the app opens on at launch.
    @Published var startupTab: NavTab {
        didSet { UserDefaults.standard.set(startupTab.rawValue, forKey: "startupTab") }
    }

    // MARK: - Onboarding

    /// True once the user has completed or skipped the first-run feature tour.
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    // MARK: - HyperView (experimental)

    /// When true, browsing a non-pinned ribbon transforms the top 2/3 of the
    /// home screen into a full-bleed backdrop with metadata for the focused item.
    /// Disabled by default — feature is still being refined.
    @Published var hyperViewEnabled: Bool {
        didSet { UserDefaults.standard.set(hyperViewEnabled, forKey: "hyperViewEnabled") }
    }

    // MARK: - PlayerLab First Frame Mode  (Sprint 44)

    /// Debug mode: prepare and render only the first keyframe, then stop.
    /// Proves the raw MKV → HEVC → CMSampleBuffer → displayLayer pipeline
    /// without requiring a full feed loop.  Off by default.
    @Published var playerLabFirstFrameMode: Bool {
        didSet { UserDefaults.standard.set(playerLabFirstFrameMode, forKey: "playerLabFirstFrameMode") }
    }

    // MARK: - PlayerLab / Playback Engine  (Sprint 15 → Sprint 43)

    /// Controls which playback engine is used.  Replaces the old `playerLabEnabled`
    /// bool with a three-way enum so the debug/off/on distinction is explicit.
    /// Default: .avPlayerOnly for a safe out-of-the-box baseline.
    @Published var playbackEngineMode: PlaybackEngineMode {
        didSet { UserDefaults.standard.set(playbackEngineMode.rawValue, forKey: "playbackEngineMode") }
    }

    /// Convenience accessor: true when PlayerLab should be consulted at all.
    /// Use this instead of reading `playbackEngineMode` in non-routing code.
    var playerLabEnabled: Bool { playbackEngineMode.playerLabEnabled }

    /// Last file path the user tested in PlayerLab — persisted across sessions.
    @Published var playerLabLastPath: String {
        didSet { UserDefaults.standard.set(playerLabLastPath, forKey: "playerLabLastPath") }
    }

    /// Sprint 43: Minimum routing confidence required for PlayerLab to take over.
    /// If PlaybackRouter returns confidence below this threshold, AVPlayer is used.
    /// Stored as Int rawValue (0 = low, 1 = medium, 2 = high). Default: high for
    /// conservative rollout — only fully-deterministic codec combinations route to
    /// PlayerLab until confidence in the codec matrix improves over sprints.
    @Published var playerLabMinConfidence: PlaybackConfidence {
        didSet { UserDefaults.standard.set(playerLabMinConfidence.rawValue, forKey: "playerLabMinConfidence") }
    }

    // MARK: - Init

    private init() {
        self.scopeUIEnabled  = UserDefaults.standard.bool(forKey: "scopeUIEnabled")
        self.homeRibbons     = Self.loadRibbons()
        self.recentSearches  = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
        let raw = UserDefaults.standard.string(forKey: "colorMode") ?? ColorMode.dark.rawValue
        self.colorMode = ColorMode(rawValue: raw) ?? .dark
        // Autoplay defaults to ON — use object(forKey:) to distinguish "not set yet" from false
        self.autoplayNextEpisode    = UserDefaults.standard.object(forKey: "autoplayNextEpisode") as? Bool ?? true
        self.subtitlesEnabled       = UserDefaults.standard.bool(forKey: "subtitlesEnabled")
        self.preferredAudioLanguage = UserDefaults.standard.string(forKey: "preferredAudioLanguage") ?? ""
        let tabRaw  = UserDefaults.standard.string(forKey: "startupTab") ?? NavTab.home.rawValue
        self.startupTab = NavTab(rawValue: tabRaw) ?? .home
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        // HyperView defaults to OFF — experimental feature, not ready for daily use
        self.hyperViewEnabled       = UserDefaults.standard.object(forKey: "hyperViewEnabled") as? Bool ?? false
        // Sprint 43: playbackEngineMode replaces the old playerLabEnabled Bool.
        // Migration: if the old Bool was saved as true, default to .playerLabPreferred;
        // otherwise default to .avPlayerOnly (safest baseline).
        let modeRaw = UserDefaults.standard.string(forKey: "playbackEngineMode")
        if let modeRaw, let mode = PlaybackEngineMode(rawValue: modeRaw) {
            self.playbackEngineMode = mode
        } else {
            // First launch or migration from old Bool key.
            let legacyEnabled = UserDefaults.standard.bool(forKey: "playerLabEnabled")
            self.playbackEngineMode = legacyEnabled ? .playerLabPreferred : .avPlayerOnly
        }
        self.playerLabFirstFrameMode = UserDefaults.standard.bool(forKey: "playerLabFirstFrameMode")
        self.playerLabLastPath      = UserDefaults.standard.string(forKey: "playerLabLastPath") ?? ""
        let confRaw = UserDefaults.standard.object(forKey: "playerLabMinConfidence") as? Int
            ?? PlaybackConfidence.high.rawValue
        self.playerLabMinConfidence = PlaybackConfidence(rawValue: confRaw) ?? .high
    }

    // MARK: - Ribbon helpers

    func moveRibbon(from source: IndexSet, to destination: Int) {
        homeRibbons.move(fromOffsets: source, toOffset: destination)
    }

    func moveUp(_ ribbon: HomeRibbon) {
        guard let idx = homeRibbons.firstIndex(where: { $0.id == ribbon.id }),
              idx > 0 else { return }
        homeRibbons.swapAt(idx, idx - 1)
    }

    func moveDown(_ ribbon: HomeRibbon) {
        guard let idx = homeRibbons.firstIndex(where: { $0.id == ribbon.id }),
              idx < homeRibbons.count - 1 else { return }
        homeRibbons.swapAt(idx, idx + 1)
    }

    func toggleRibbon(_ ribbon: HomeRibbon) {
        guard let idx = homeRibbons.firstIndex(where: { $0.id == ribbon.id }) else { return }
        homeRibbons[idx].enabled.toggle()
    }

    func addRibbon(_ ribbon: HomeRibbon) {
        guard !homeRibbons.contains(where: { $0.type == ribbon.type }) else { return }
        homeRibbons.append(ribbon)
    }

    func removeRibbon(_ ribbon: HomeRibbon) {
        homeRibbons.removeAll { $0.id == ribbon.id }
    }

    func resetToDefaults() {
        homeRibbons = HomeRibbon.defaults
    }

    // MARK: - Recent Search helpers

    func addRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var updated = recentSearches.filter { $0.lowercased() != trimmed.lowercased() }
        updated.insert(trimmed, at: 0)
        recentSearches = Array(updated.prefix(8))
    }

    func clearRecentSearches() {
        recentSearches = []
    }

    // MARK: - Persistence

    private func saveRibbons() {
        if let data = try? JSONEncoder().encode(homeRibbons) {
            UserDefaults.standard.set(data, forKey: "homeRibbons")
        }
    }

    private static func loadRibbons() -> [HomeRibbon] {
        guard let data = UserDefaults.standard.data(forKey: "homeRibbons"),
              let ribbons = try? JSONDecoder().decode([HomeRibbon].self, from: data),
              !ribbons.isEmpty
        else { return HomeRibbon.defaults }
        return ribbons
    }
}
