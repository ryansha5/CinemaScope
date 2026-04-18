import Foundation
import Combine

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

    // MARK: - PlayerLab  (Sprint 15)

    /// When true the PlayerLab custom playback engine is enabled.
    /// Compatible local MP4 files (H.264/HEVC + AAC) can be played through
    /// PlayerLab instead of AVPlayer.  Default: false.
    @Published var playerLabEnabled: Bool {
        didSet { UserDefaults.standard.set(playerLabEnabled, forKey: "playerLabEnabled") }
    }

    /// Last file path the user tested in PlayerLab — persisted across sessions.
    @Published var playerLabLastPath: String {
        didSet { UserDefaults.standard.set(playerLabLastPath, forKey: "playerLabLastPath") }
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
        self.playerLabEnabled       = UserDefaults.standard.bool(forKey: "playerLabEnabled")
        self.playerLabLastPath      = UserDefaults.standard.string(forKey: "playerLabLastPath") ?? ""
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
