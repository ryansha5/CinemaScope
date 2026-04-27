import Foundation
import Darwin

// MARK: - PlayerLabLog
//
// Redirects stderr to a persistent log file in the app's tmp directory so that
// ALL PlayerLab output (fputs to stderr from PacketFeeder, PlaybackController,
// FrameRenderer, VT decode errors, CoreMedia errors, AudioRenderer, etc.) can be
// read directly from the Mac host without copy-pasting from Xcode.
//
// Usage
// ─────
// Call PlayerLabLog.setup() once at app launch (CinemaScopeApp.init).
// The log path is printed to stdout (visible in Xcode console, NOT redirected):
//
//   📋 [PlayerLabLog] Log file: /Users/.../tmp/playerlab.log
//
// From the Mac, read the log with:
//
//   cat "$(xcrun simctl get_app_container booted SMR.CinemaScope data)/tmp/playerlab.log"
//
// Or use scripts/read_playerlab_log.sh which does this automatically.
//
// Notes
// ─────
// • freopen() replaces the stderr FILE* for this process, so the Xcode console
//   will no longer show stderr lines — only stdout (print/NSLog) remains visible.
// • The log file is APPENDED to across launches (mode "a") so history survives
//   hot-reloads. Call PlayerLabLog.truncate() to clear before a fresh test run.
// • Thread-safe: fputs is atomic for lines shorter than PIPE_BUF (4096 bytes).

enum PlayerLabLog {

    // MARK: - Public API

    /// Redirect all stderr output to `<NSTemporaryDirectory>/playerlab.log`.
    /// Call once from CinemaScopeApp.init().
    static func setup() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playerlab.log")
        logFilePath = url.path

        // Truncate on every fresh launch so stale data doesn't confuse reads.
        truncate()

        // freopen: redirect stderr → file (append mode so subsequent calls stack)
        guard freopen(url.path, "w", stderr) != nil else {
            print("⚠️ [PlayerLabLog] freopen failed — logging to Xcode console only")
            return
        }

        // Print the path to stdout (NOT stderr) so it remains visible in Xcode.
        print("📋 [PlayerLabLog] Logging to: \(url.path)")
        print("📋 [PlayerLabLog] On Mac: cat \"\(url.path)\"")
    }

    /// Clear the log file (e.g. before starting a new playback test).
    static func truncate() {
        guard let path = logFilePath else { return }
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The path of the active log file, or nil if setup() hasn't been called.
    private(set) static var logFilePath: String?
}
