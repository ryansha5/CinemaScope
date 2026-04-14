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

    // MARK: - Init

    private init() {
        self.scopeUIEnabled = UserDefaults.standard.bool(forKey: "scopeUIEnabled")
        self.homeRibbons    = Self.loadRibbons()
        let raw = UserDefaults.standard.string(forKey: "colorMode") ?? ColorMode.dark.rawValue
        self.colorMode = ColorMode(rawValue: raw) ?? .dark
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
