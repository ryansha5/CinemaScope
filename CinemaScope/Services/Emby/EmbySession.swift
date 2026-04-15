import Foundation
import Security

// MARK: - EmbySession

/// Holds authenticated session state and persists it to Keychain.
/// Shared across the app via @EnvironmentObject.
@MainActor
final class EmbySession: ObservableObject {

    @Published private(set) var server: EmbyServer?
    @Published private(set) var user:   EmbyUser?
    @Published private(set) var token:  String?

    var isAuthenticated: Bool { token != nil && user != nil }

    private let keychainKey = "cinemascope.emby.session"

    init() {
        loadFromKeychain()
    }

    // MARK: - Login / Logout

    func login(server: EmbyServer, user: EmbyUser, token: String) {
        self.server = server
        self.user   = user
        self.token  = token
        saveToKeychain()
    }

    func logout() {
        server = nil
        user   = nil
        token  = nil
        deleteFromKeychain()
    }

    // MARK: - Keychain

    private func saveToKeychain() {
        guard let server, let user, let token else { return }
        let payload: [String: String] = [
            "serverURL": server.url,
            "userId":    user.id,
            "userName":  user.name,
            "token":     token,
        ]
        guard let data = try? JSONEncoder().encode(payload) else { return }

        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: keychainKey,
            kSecValueData:   data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain() {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      keychainKey,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let payload = try? JSONDecoder().decode([String: String].self, from: data),
              let serverURL = payload["serverURL"],
              let userId    = payload["userId"],
              let userName  = payload["userName"],
              let token     = payload["token"]
        else { return }

        self.server = EmbyServer(url: serverURL)
        self.user   = EmbyUser(id: userId, name: userName, primaryImageTag: nil)
        self.token  = token
    }

    private func deleteFromKeychain() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: keychainKey,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
