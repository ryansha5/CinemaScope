import Foundation
import Security

// MARK: - PINEAEnvironment
//
// Single source of truth for authentication, routing, and library access state.
//
// Screen routing (CinemaScopeApp):
//   isAuthenticated == false                          → WelcomeView
//   isAuthenticated && !hasLibraryConnection          → ServerSetupView
//   isAuthenticated && hasLibraryConnection
//     && !hasCompletedOnboarding                      → OnboardingView
//   all above true                                    → HomeView
//
// Library access mode (Sprint 4):
//   libraryAccessMode == .checking                    → startup in progress
//   libraryAccessMode == .none                        → no usable library state
//   libraryAccessMode == .snapshot                    → backend metadata available
//   libraryAccessMode == .liveReady                   → live Emby connection ready
//
// Playback is always direct-to-Emby; libraryAccessMode governs metadata only.

@MainActor
final class PINEAEnvironment: ObservableObject {

    // MARK: - Routing state

    @Published private(set) var isAuthenticated:          Bool = false
    @Published private(set) var hasLibraryConnection:      Bool = false
    /// True while the app is checking the PINEA backend for an existing
    /// library connection (e.g. on first launch after a token restore).
    @Published private(set) var isCheckingLibraryConnection: Bool = false
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.onboarded) }
    }

    // MARK: - Sprint 5: Session state
    //
    // Read-only observation of the backend session.
    // PINEA never drives playback from this state — it is awareness only.

    /// The most recently fetched backend session, or nil if none exists.
    @Published private(set) var currentSession:      PINEASession?          = nil
    /// Derived playback state from the current session. Nil when no session.
    @Published private(set) var currentSessionState: PINEASessionPlaybackState? = nil
    /// The Emby item ID associated with the current session's movie, if any.
    @Published private(set) var selectedMovieId:     String?               = nil
    /// Lightweight movie summary from the current session, if available.
    @Published private(set) var selectedMovieSummary: PINEASessionMovieSummary? = nil
    /// True while a session fetch is in progress.
    @Published private(set) var isCheckingSession:   Bool                  = false
    /// Non-nil when the session fetch fails.
    @Published private(set) var sessionError:        PINEAServiceError?    = nil

    // MARK: - Sprint 3 + 4: Library snapshot state

    /// True when the backend has a stored library snapshot for this user.
    @Published private(set) var hasLibrarySnapshot:       Bool               = false
    /// True while a sync is in progress.
    @Published private(set) var isSyncingLibrary:         Bool               = false
    /// True while checkLibrarySnapshot / fetchLibrarySnapshot is running.
    @Published private var    isCheckingLibrarySnapshot:  Bool               = false
    /// Timestamp of the most recent successful sync (persisted across launches).
    @Published private(set) var lastLibrarySyncAt:        Date?              = nil
    /// Lightweight metadata items from the backend snapshot.
    @Published private(set) var libraryItems:             [PINEALibraryItem] = []
    /// Non-nil when a library status/fetch/sync call fails.
    @Published private(set) var libraryError:             PINEAServiceError? = nil

    // MARK: - Sprint 5: Convenience accessors

    /// True when a backend session exists (any state).
    var hasActiveSession: Bool { currentSession != nil }

    /// True when the backend session is currently playing or buffering.
    var isSessionPlaying: Bool {
        currentSessionState == .playing || currentSessionState == .buffering
    }

    // MARK: - Sprint 4: Library access mode

    /// True while any library connectivity check is running.
    /// Combines the Sprint 2 connection check and the Sprint 3 snapshot check.
    var isCheckingLibrary: Bool {
        isCheckingLibraryConnection || isCheckingLibrarySnapshot
    }

    /// Derived access mode — computed from published flags, reactive automatically.
    /// Playback never depends on this; it governs metadata and UI state only.
    var libraryAccessMode: PINEALibraryAccessMode {
        if isCheckingLibrary                          { return .checking  }
        if hasLibraryConnection                       { return .liveReady }
        if hasLibrarySnapshot && !libraryItems.isEmpty { return .snapshot  }
        return .none
    }

    // MARK: - User

    @Published private(set) var currentUser: PINEAUser? = nil

    // MARK: - Backend URL

    /// URL of the PINEA platform backend, e.g. "https://api.pinea.tv"
    @Published var backendBaseURL: String {
        didSet { UserDefaults.standard.set(backendBaseURL, forKey: Keys.backendURL) }
    }

    // MARK: - Emby session (transitional bridge)

    /// Hydrated when a library connection is established.
    /// Passed as an EnvironmentObject to HomeView and all Emby-dependent screens.
    let embySession = EmbySession()

    // MARK: - Init

    init() {
        self.backendBaseURL         = UserDefaults.standard.string(forKey: Keys.backendURL) ?? ""
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Keys.onboarded)

        // Restore last sync timestamp
        let syncInterval = UserDefaults.standard.double(forKey: Keys.lastSyncAt)
        self.lastLibrarySyncAt = syncInterval > 0 ? Date(timeIntervalSince1970: syncInterval) : nil

        // Sprint 8: resolve device identity once at init (generate if first launch)
        self._deviceIdentity = DeviceIdentity.current()
        #if DEBUG
        print("[PINEAEnvironment] deviceId=\(_deviceIdentity.deviceId)  deviceName=\(_deviceIdentity.deviceName)")
        #endif

        // Restore token if one was previously persisted
        if let token = PINEAEnvironment.readToken() {
            self.isAuthenticated      = true
            self._token               = token
            self.hasLibraryConnection = embySession.isAuthenticated

            // Background: library check + device registration (non-blocking)
            Task { await startupLibraryCheck() }
            Task { await registerDevice() }
        }
    }

    // MARK: - Auth lifecycle

    func didAuthenticate(user: PINEAUser, token: String) {
        PINEAEnvironment.writeToken(token)
        _token           = token
        currentUser      = user
        isAuthenticated  = true

        // Sprint 8: register device now that we have a valid token.
        Task { await registerDevice() }

        // Fast-path: Emby session already hydrated from keychain
        if embySession.isAuthenticated {
            hasLibraryConnection = true
            // Background: check snapshot status — non-blocking.
            Task { await checkLibrarySnapshot() }
            return
        }

        // Async-path: check connection then snapshot in sequence.
        // Non-fatal — if the backend is unreachable the user sees ServerSetupView.
        Task { await checkLibraryConnection() }
    }

    // MARK: - Sprint 8: Device registration

    /// Registers (or heartbeats) this device with the PINEA backend.
    /// Fire-and-forget — never throws, never blocks navigation.
    func registerDevice() async {
        guard let token = _token, !backendBaseURL.isEmpty else { return }
        await DeviceService.shared.registerDevice(
            baseURL:  backendBaseURL,
            token:    token,
            identity: _deviceIdentity
        )
    }

    /// The stable device identity for this installation.
    var deviceIdentity: DeviceIdentity { _deviceIdentity }

    // MARK: - Library connection check (Sprint 2)

    /// Queries GET /api/me/library-connection.
    /// Updates hasLibraryConnection when a confirmed connection is found.
    /// Safe to call repeatedly — guards against concurrent execution.
    func checkLibraryConnection() async {
        guard isAuthenticated,
              !backendBaseURL.isEmpty,
              let token = _token,
              !isCheckingLibraryConnection
        else { return }

        isCheckingLibraryConnection = true
        defer { isCheckingLibraryConnection = false }

        do {
            let status = try await ServerService.shared.fetchConnectionStatus(
                baseURL: backendBaseURL,
                token:   token
            )
            if status.connected {
                hasLibraryConnection = true
                // Chain: now that connection is confirmed, check snapshot status.
                await checkLibrarySnapshot()
            }
        } catch {
            // Backend unreachable or token invalid — leave state as-is.
            // The user can connect manually via ServerSetupView.
        }
    }

    // MARK: - Sprint 3 + 5: Startup library + session check

    /// Called once on launch when a persisted token is restored.
    /// Sequences: connection check → snapshot check → session check.
    /// Nothing here blocks the UI or affects the Emby playback path.
    private func startupLibraryCheck() async {
        if hasLibraryConnection {
            await checkLibrarySnapshot()
        } else {
            await checkLibraryConnection()
            // checkLibraryConnection chains into checkLibrarySnapshot on success.
        }
        // After library state is resolved, fetch session state in the background.
        await checkCurrentSession()
    }

    // MARK: - Sprint 3: Library snapshot

    /// Checks GET /api/me/library/status.
    /// If a snapshot exists, immediately fetches it into libraryItems.
    /// If not, hasLibrarySnapshot = false — UI can offer a sync action.
    /// Sets isCheckingLibrarySnapshot (→ libraryAccessMode = .checking) for its duration.
    /// Non-fatal and non-blocking — never gates playback.
    func checkLibrarySnapshot() async {
        guard isAuthenticated,
              !backendBaseURL.isEmpty,
              let token = _token,
              !isCheckingLibrarySnapshot
        else { return }

        isCheckingLibrarySnapshot = true
        libraryError = nil
        defer { isCheckingLibrarySnapshot = false }

        do {
            let status = try await LibraryService.shared.fetchLibraryStatus(
                baseURL: backendBaseURL,
                token:   token
            )
            hasLibrarySnapshot = status.hasSnapshot
            if let syncedAt = status.lastSyncedAt {
                persistSyncDate(syncedAt)
            }
            if status.hasSnapshot {
                // isCheckingLibrarySnapshot already true; fetchLibrarySnapshot
                // skips its own guard to avoid double-toggle.
                await fetchLibrarySnapshotInternal(token: token)
            }
        } catch {
            // Snapshot check failed — leave current state; don't surface to user.
        }
    }

    /// Fetches GET /api/me/library and populates libraryItems.
    /// Public — safe to call for pull-to-refresh patterns.
    func fetchLibrarySnapshot() async {
        guard isAuthenticated,
              !backendBaseURL.isEmpty,
              let token = _token,
              !isCheckingLibrarySnapshot
        else { return }

        isCheckingLibrarySnapshot = true
        defer { isCheckingLibrarySnapshot = false }
        await fetchLibrarySnapshotInternal(token: token)
    }

    /// Internal fetch — called when the flag is already held by the caller.
    private func fetchLibrarySnapshotInternal(token: String) async {
        do {
            let items = try await LibraryService.shared.fetchLibrary(
                baseURL: backendBaseURL,
                token:   token
            )
            libraryItems       = items
            hasLibrarySnapshot = true
            libraryError       = nil
        } catch let error as PINEAServiceError {
            libraryError = error
        } catch {
            libraryError = PINEAServiceError(message: error.localizedDescription)
        }
    }

    // MARK: - Sprint 7: Stale session handling

    /// Clears only the session movie references without touching auth, library, or full session state.
    /// Called when an Emby item fetch fails for the selected movie ID, indicating the selection is stale.
    func clearStaleSessionMovie() {
        selectedMovieId      = nil
        selectedMovieSummary = nil
        // currentSession / currentSessionState deliberately preserved — only the
        // movie pointer is stale. The session itself may still be valid.
    }

    /// Triggers POST /api/me/library/sync, then re-fetches the snapshot.
    /// Call from a UI action (e.g. a "Sync Library" button in Settings).
    func syncLibrary() async {
        guard isAuthenticated,
              !backendBaseURL.isEmpty,
              let token = _token,
              !isSyncingLibrary
        else { return }

        isSyncingLibrary          = true
        isCheckingLibrarySnapshot = true
        libraryError              = nil
        defer {
            isSyncingLibrary          = false
            isCheckingLibrarySnapshot = false
        }

        do {
            let result = try await LibraryService.shared.syncLibrary(
                baseURL: backendBaseURL,
                token:   token
            )
            if let syncedAt = result.syncedAt {
                persistSyncDate(syncedAt)
            }
            // Re-fetch using internal path since flags are already held.
            await fetchLibrarySnapshotInternal(token: token)
        } catch let error as PINEAServiceError {
            libraryError = error
        } catch {
            libraryError = PINEAServiceError(message: error.localizedDescription)
        }
    }

    // MARK: - Sprint 5: Session check

    /// Fetches GET /api/me/session/current and updates session state.
    /// Non-fatal — failure clears session state silently.
    /// Never blocks launch or affects playback.
    func checkCurrentSession() async {
        guard isAuthenticated,
              !backendBaseURL.isEmpty,
              let token = _token,
              !isCheckingSession
        else { return }

        isCheckingSession = true
        sessionError      = nil
        defer { isCheckingSession = false }

        do {
            let session = try await SessionService.shared.fetchCurrentSession(
                baseURL: backendBaseURL,
                token:   token
            )
            applySession(session)
        } catch let error as PINEAServiceError {
            sessionError = error
            applySession(nil)
        } catch {
            sessionError = PINEAServiceError(message: error.localizedDescription)
            applySession(nil)
        }
    }

    /// Applies a fetched session (or nil) to all derived session properties atomically.
    private func applySession(_ session: PINEASession?) {
        currentSession       = session
        currentSessionState  = session?.state
        selectedMovieId      = session?.movie?.id
        selectedMovieSummary = session?.movie
    }

    // MARK: - Private helpers

    private func persistSyncDate(_ date: Date) {
        lastLibrarySyncAt = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Keys.lastSyncAt)
    }

    func didConnectLibrary(server: EmbyServer, user: EmbyUser, token: String) {
        embySession.login(server: server, user: user, token: token)
        hasLibraryConnection = true
        // Background: snapshot + session + device heartbeat — non-blocking.
        Task {
            await checkLibrarySnapshot()
            await checkCurrentSession()
            await registerDevice()
        }
    }

    func signOut() {
        PINEAEnvironment.deleteToken()
        _token                = nil
        currentUser           = nil
        isAuthenticated       = false
        hasLibraryConnection  = false
        hasLibrarySnapshot        = false
        isSyncingLibrary          = false
        isCheckingLibrarySnapshot = false
        lastLibrarySyncAt         = nil
        libraryItems              = []
        libraryError              = nil
        currentSession            = nil
        currentSessionState       = nil
        selectedMovieId           = nil
        selectedMovieSummary      = nil
        isCheckingSession         = false
        sessionError              = nil
        embySession.logout()
    }

    /// The active PINEA JWT — used by services when making authenticated API calls.
    var pineaToken: String? { _token }

    // MARK: - Sprint 1: Simulated auth
    //
    // Toggles isAuthenticated without a network call.
    // Use during development until the PINEA backend is integrated.
    // Remove — or gate behind a build flag — before shipping.
    func simulateLogin() {
        didAuthenticate(
            user:  PINEAUser(id: "dev", username: "Developer", email: "dev@pinea.tv"),
            token: "simulated-dev-token"
        )
    }

    // MARK: - Private

    private var _token:          String?         = nil
    private var _deviceIdentity: DeviceIdentity  = DeviceIdentity.current()
                                                   // overwritten in init() before use

    // MARK: - Keychain helpers

    private static let tokenAccount = "pinea.platform.jwt"
    private static let tokenService = "com.pinea.cinemascope"

    private static func writeToken(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: tokenService,
            kSecAttrAccount: tokenAccount,
            kSecValueData:   data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func readToken() -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      tokenService,
            kSecAttrAccount:      tokenAccount,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    private static func deleteToken() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: tokenService,
            kSecAttrAccount: tokenAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - UserDefaults keys

    private enum Keys {
        static let backendURL = "pinea.backendBaseURL"
        static let onboarded  = "pinea.hasCompletedOnboarding"
        static let lastSyncAt = "pinea.lastLibrarySyncAt"
    }
}

// MARK: - AppEnvironment
//
// PINEAEnvironment IS the AppEnvironment defined in Sprint 1.
// Alias kept for call-sites that reference the sprint name directly.
typealias AppEnvironment = PINEAEnvironment
