import Foundation
import Combine

// MARK: - AppSettings
// Holds user preferences that persist across launches.
// CinemaScope UI mode lives here — manual toggle only.

final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    @Published var scopeUIEnabled: Bool {
        didSet { UserDefaults.standard.set(scopeUIEnabled, forKey: "scopeUIEnabled") }
    }

    private init() {
        self.scopeUIEnabled = UserDefaults.standard.bool(forKey: "scopeUIEnabled")
    }
}
