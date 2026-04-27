import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - DeviceIdentity
//
// Sprint 8: generate-once, persist-forever device identity for this PINEA instance.
// Never recreated after the first launch — survives app updates (UserDefaults).
// Exposed as a value type so any service can read it without going through the environment.

struct DeviceIdentity {

    let deviceId:   String
    let deviceName: String

    private enum Keys {
        static let deviceId   = "pinea.deviceId"
        static let deviceName = "pinea.deviceName"
    }

    // Returns the persisted identity, creating it once if absent.
    static func current() -> DeviceIdentity {
        let ud = UserDefaults.standard

        // deviceId — generate once, never regenerate
        let id: String
        if let stored = ud.string(forKey: Keys.deviceId), !stored.isEmpty {
            id = stored
        } else {
            let fresh = UUID().uuidString
            ud.set(fresh, forKey: Keys.deviceId)
            id = fresh
        }

        // deviceName — persist so users can later customise it; default from OS
        let name: String
        if let stored = ud.string(forKey: Keys.deviceName), !stored.isEmpty {
            name = stored
        } else {
            let derived = DeviceIdentity.platformDeviceName()
            ud.set(derived, forKey: Keys.deviceName)
            name = derived
        }

        return DeviceIdentity(deviceId: id, deviceName: name)
    }

    // Overwrite the stored name (no UI yet — available for future customisation).
    static func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: Keys.deviceName)
    }

    // MARK: - Platform device name

    private static func platformDeviceName() -> String {
#if canImport(UIKit)
        let name = UIDevice.current.name
        return name.isEmpty ? "PINEA Device" : name
#else
        return ProcessInfo.processInfo.hostName.isEmpty
            ? "PINEA Device"
            : ProcessInfo.processInfo.hostName
#endif
    }
}

// MARK: - DeviceService
//
// Sprint 8: registers this device with the PINEA backend and provides a
// heartbeat mechanism (re-register) to keep lastSeenAt current.
//
// Route:
//   POST /api/me/devices/register
//
// Contract:
//   • fire-and-forget — caller never awaits a result
//   • silent failure — no crash, no user-visible error
//   • idempotent — safe to call on every launch and every foreground return

actor DeviceService {

    static let shared = DeviceService()
    private init() {}

    private enum Route {
        static let register = "/api/me/devices/register"
    }

    // MARK: - registerDevice

    /// POST /api/me/devices/register
    /// Registers (or refreshes) this device on the PINEA backend.
    /// Updates the backend's `lastSeenAt` on every call — acts as a heartbeat.
    func registerDevice(
        baseURL:  String,
        token:    String,
        identity: DeviceIdentity
    ) async {
        guard !baseURL.isEmpty, !token.isEmpty else {
            log("⚠️  registerDevice skipped — missing baseURL or token")
            return
        }

        log("📱 Registering device '\(identity.deviceName)' [\(identity.deviceId)]")

        guard let url = URL(string: normalised(baseURL) + Route.register) else {
            log("⚠️  registerDevice — invalid URL: \(baseURL)")
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")

        let body: [String: String] = [
            "device_id":   identity.deviceId,
            "device_name": identity.deviceName,
            "platform":    platform,
        ]

        do {
            req.httpBody = try JSONEncoder().encode(body)
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    log("✅ Device registered — status \(http.statusCode)")
                } else {
                    log("⚠️  Device registration returned HTTP \(http.statusCode)")
                }
            }
        } catch {
            log("⚠️  Device registration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private var platform: String {
#if os(tvOS)
        return "tvOS"
#elseif os(iOS)
        return "iOS"
#else
        return "macOS"
#endif
    }

    private func normalised(_ url: String) -> String {
        url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    private func log(_ message: String) {
#if DEBUG
        print("[DeviceService] \(message)")
#endif
    }
}
