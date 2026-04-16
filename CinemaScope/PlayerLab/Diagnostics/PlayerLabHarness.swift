import Foundation

// MARK: - PlayerLabHarness
//
// Standalone test driver for the PlayerLab subsystem.
//
// Design goals:
//   • No dependency on the main app UI or AVPlayer
//   • Every action is logged in full — URL, byte counts, errors, state transitions
//   • Results accumulate in `log` so callers can inspect them programmatically
//     (useful when driven from an XCTest target)
//   • Public async methods can be called from a Swift Playground, a test target,
//     or a hidden debug menu in the app — the harness doesn't care
//
// Usage (from anywhere — see sample at bottom of file):
//
//   let harness = await PlayerLabHarness()
//   await harness.runBasicLocalRead(url: URL(fileURLWithPath: "/path/to/file.mkv"))
//   print(harness.formattedLog)

// MARK: - Log entry

struct LabLogEntry: Sendable {
    enum Level: String, Sendable {
        case info    = "ℹ️"
        case success = "✅"
        case warning = "⚠️"
        case error   = "❌"
        case data    = "📦"
    }

    let timestamp: Date
    let level: Level
    let message: String

    var formatted: String {
        let ts = ISO8601DateFormatter().string(from: timestamp)
        return "[\(ts)][\(level.rawValue)] \(message)"
    }
}

// MARK: - Harness

@MainActor
final class PlayerLabHarness {

    // MARK: State

    let engine = PlayerLabEngine()

    private(set) var log: [LabLogEntry] = []

    // MARK: Init

    init() {
        record(.info, "PlayerLabHarness initialized")
        record(.info, "Engine state: \(engine.playbackState)")
    }

    // MARK: - Sprint 4: Engine state cycle
    //
    // Drives PlayerLabEngine through a controlled sequence of calls and logs
    // every state transition.  No real media is involved.

    func runEngineStateCycle() {
        record(.info, "─── Engine State Cycle ───")

        let url = URL(string: "playerlab://test/dummy.mkv")!

        record(.info, "Calling setPlaybackContext(scopeUIEnabled: true, serverURL: '', itemId: 'test-01')")
        engine.setPlaybackContext(scopeUIEnabled: true, serverURL: "", itemId: "test-01")
        record(.info, "scopeUIEnabled = \(engine.scopeUIEnabled)")

        record(.info, "Calling load(url: \(url), startTicks: 0)")
        engine.load(url: url, startTicks: 0)
        record(.info, "State after load: \(engine.playbackState)")

        record(.info, "Calling play()")
        engine.play()
        record(.info, "State after play: \(engine.playbackState)")

        record(.info, "Calling pause()")
        engine.pause()
        record(.info, "State after pause: \(engine.playbackState)")

        record(.info, "Calling seek(to: 0.5)")
        engine.seek(to: 0.5)
        record(.info, "currentTime = \(engine.currentTime), duration = \(engine.duration)")

        record(.info, "Calling stop()")
        engine.stop()
        record(.info, "State after stop: \(engine.playbackState)")
        record(.info, "currentTime = \(engine.currentTime), duration = \(engine.duration)")

        record(.success, "Engine state cycle complete")
    }

    // MARK: - Sprint 6: File read validation
    //
    // Wires MediaReader to prove byte-level file access works before any parsing.

    func runBasicLocalRead(url: URL) async {
        record(.info, "─── Basic Local Read ───")
        record(.info, "URL: \(url.path)")

        let reader = MediaReader(url: url)

        // Step 1: Open
        record(.info, "Opening reader…")
        do {
            try await reader.open()
            record(.success, "Reader opened. Content-Length: \(formatBytes(reader.contentLength))")
            record(.info, "Supports byte ranges: \(reader.supportsByteRanges)")
        } catch {
            record(.error, "Failed to open: \(error)")
            return
        }

        // Step 2: Read first 256 bytes
        record(.info, "Reading first 256 bytes…")
        do {
            let header = try await reader.read(offset: 0, length: 256)
            record(.data, "Read \(header.count) bytes from offset 0")
            record(.data, "First 16 bytes (hex): \(hexString(header.prefix(16)))")

            // Detect container magic bytes for future use
            detectMagicBytes(header, in: &self.log)
        } catch {
            record(.error, "Failed to read header: \(error)")
        }

        // Step 3: Read a mid-file range (if file is large enough)
        let midOffset = reader.contentLength / 2
        if midOffset > 256 {
            record(.info, "Reading 512 bytes at mid-file offset \(midOffset)…")
            do {
                let midChunk = try await reader.read(offset: midOffset, length: 512)
                record(.data, "Read \(midChunk.count) bytes at offset \(midOffset)")
                record(.success, "Byte-range read verified")
            } catch {
                record(.error, "Failed mid-file read: \(error)")
            }
        } else {
            record(.warning, "File too small for mid-file range test (size: \(formatBytes(reader.contentLength)))")
        }

        // Step 4: Read last 64 bytes
        let tailOffset = max(0, reader.contentLength - 64)
        record(.info, "Reading 64 bytes at tail offset \(tailOffset)…")
        do {
            let tail = try await reader.read(offset: tailOffset, length: 64)
            record(.data, "Read \(tail.count) bytes at offset \(tailOffset)")
        } catch {
            record(.error, "Failed tail read: \(error)")
        }

        // Step 5: Stability — repeat first read and verify byte-for-byte match
        record(.info, "Stability check: repeating first 256-byte read…")
        do {
            let header2 = try await reader.read(offset: 0, length: 256)
            let match = header2.prefix(256) == (try await reader.read(offset: 0, length: 256)).prefix(256)
            if match {
                record(.success, "Stability check passed — repeated reads are consistent")
            } else {
                record(.warning, "Stability check: repeated reads returned different data!")
            }
        } catch {
            record(.error, "Stability check failed: \(error)")
        }

        record(.success, "Basic local read complete")
    }

    func runBasicRemoteRead(url: URL) async {
        record(.info, "─── Basic Remote Read ───")
        record(.info, "URL: \(url.absoluteString)")

        let reader = MediaReader(url: url)

        record(.info, "Opening remote reader…")
        do {
            try await reader.open()
            record(.success, "Remote reader opened.")
            record(.info, "Content-Length: \(formatBytes(reader.contentLength))")
            record(.info, "Content-Type: \(reader.contentType ?? "(unknown)")")
            record(.info, "Supports byte ranges: \(reader.supportsByteRanges)")
        } catch {
            record(.error, "Failed to open remote URL: \(error)")
            return
        }

        record(.info, "Reading first 256 bytes via HTTP range…")
        do {
            let header = try await reader.read(offset: 0, length: 256)
            record(.data, "Read \(header.count) bytes")
            record(.data, "First 16 bytes (hex): \(hexString(header.prefix(16)))")
            detectMagicBytes(header, in: &self.log)
            record(.success, "Remote read complete")
        } catch {
            record(.error, "Remote read failed: \(error)")
        }
    }

    // MARK: - Log helpers

    func record(_ level: LabLogEntry.Level, _ message: String) {
        let entry = LabLogEntry(timestamp: Date(), level: level, message: message)
        log.append(entry)
        // Also emit to stderr so Xcode console shows it live
        fputs(entry.formatted + "\n", stderr)
    }

    var formattedLog: String {
        log.map(\.formatted).joined(separator: "\n")
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: - Utilities

    private func hexString<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func formatBytes(_ count: Int) -> String {
        if count < 0 { return "unknown" }
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f KB", Double(count) / 1024) }
        return String(format: "%.2f MB", Double(count) / (1024 * 1024))
    }

    private func detectMagicBytes(_ data: Data, in log: inout [LabLogEntry]) {
        let bytes = Array(data.prefix(12))
        guard bytes.count >= 4 else { return }

        // EBML / Matroska
        if bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 {
            let entry = LabLogEntry(timestamp: Date(), level: .info,
                                   message: "Magic bytes: EBML/Matroska (MKV/WebM) detected")
            log.append(entry); fputs(entry.formatted + "\n", stderr)
            return
        }
        // ISO Base Media (MP4/MOV/M4V)
        if bytes.count >= 8 {
            let ftyp = bytes[4...7].map { Character(UnicodeScalar($0)) }
            if String(ftyp) == "ftyp" {
                let entry = LabLogEntry(timestamp: Date(), level: .info,
                                       message: "Magic bytes: ISO Base Media (MP4/MOV) detected")
                log.append(entry); fputs(entry.formatted + "\n", stderr)
                return
            }
        }
        // MPEG-TS
        if bytes[0] == 0x47 {
            let entry = LabLogEntry(timestamp: Date(), level: .info,
                                   message: "Magic bytes: MPEG-TS detected")
            log.append(entry); fputs(entry.formatted + "\n", stderr)
            return
        }
        // Unknown
        let entry = LabLogEntry(timestamp: Date(), level: .info,
                                message: "Magic bytes: unrecognized — \(bytes.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " "))")
        log.append(entry); fputs(entry.formatted + "\n", stderr)
    }
}

/*
 ──────────────────────────────────────────────────────────────────────────────
 HOW TO RUN LOCALLY (no Xcode test target needed yet)
 ──────────────────────────────────────────────────────────────────────────────

 Option A — Swift Playground (quickest)
   1. File > New > Playground… (macOS, tvOS, or iOS)
   2. Import CinemaScope module or paste the relevant types
   3. Instantiate and call:

      let harness = await PlayerLabHarness()
      harness.runEngineStateCycle()
      print(harness.formattedLog)

      // File read:
      let url = URL(fileURLWithPath: "/Users/shane/Downloads/test.mkv")
      await harness.runBasicLocalRead(url: url)
      print(harness.formattedLog)

 Option B — Hidden debug menu in the app (no test target needed)
   Add a button in SettingsView (debug builds only):

      #if DEBUG
      Button("Run PlayerLab Harness") {
          Task { @MainActor in
              let h = PlayerLabHarness()
              h.runEngineStateCycle()
              // point at a real file on the device if available
          }
      }
      #endif

 Option C — XCTest target (future)
   1. Add a new test target: PlayerLabTests
   2. Import CinemaScope
   3. Instantiate PlayerLabHarness in setUp()
   4. Assert on h.log entries after each runXxx() call

 ──────────────────────────────────────────────────────────────────────────────
 EXPECTED LOG OUTPUT (engine state cycle, no real file)
 ──────────────────────────────────────────────────────────────────────────────

 [2026-04-15T...][ℹ️] PlayerLabHarness initialized
 [2026-04-15T...][ℹ️] Engine state: idle
 [2026-04-15T...][ℹ️] ─── Engine State Cycle ───
 [2026-04-15T...][ℹ️] Calling setPlaybackContext(…)
 [2026-04-15T...][ℹ️] scopeUIEnabled = true
 [2026-04-15T...][ℹ️] Calling load(url: playerlab://test/dummy.mkv, startTicks: 0)
 [2026-04-15T...][ℹ️] State after load: idle
 [2026-04-15T...][ℹ️] Calling play()
 [2026-04-15T...][ℹ️] State after play: idle
 [2026-04-15T...][ℹ️] Calling pause()
 [2026-04-15T...][ℹ️] State after pause: idle
 [2026-04-15T...][ℹ️] Calling seek(to: 0.5)
 [2026-04-15T...][ℹ️] currentTime = 0.0, duration = 0.0
 [2026-04-15T...][ℹ️] Calling stop()
 [2026-04-15T...][ℹ️] State after stop: idle
 [2026-04-15T...][ℹ️] currentTime = 0.0, duration = 0.0
 [2026-04-15T...][✅] Engine state cycle complete

 ──────────────────────────────────────────────────────────────────────────────
 EXPECTED LOG OUTPUT (local MKV read)
 ──────────────────────────────────────────────────────────────────────────────

 [2026-04-15T...][ℹ️] ─── Basic Local Read ───
 [2026-04-15T...][ℹ️] URL: /Users/shane/Downloads/test.mkv
 [2026-04-15T...][ℹ️] Opening reader…
 [2026-04-15T...][✅] Reader opened. Content-Length: 1.45 GB
 [2026-04-15T...][ℹ️] Supports byte ranges: true
 [2026-04-15T...][ℹ️] Reading first 256 bytes…
 [2026-04-15T...][📦] Read 256 bytes from offset 0
 [2026-04-15T...][📦] First 16 bytes (hex): 1a 45 df a3 01 00 00 00 00 00 00 1f 42 86 81 01
 [2026-04-15T...][ℹ️] Magic bytes: EBML/Matroska (MKV/WebM) detected
 [2026-04-15T...][ℹ️] Reading 512 bytes at mid-file offset 777216000…
 [2026-04-15T...][📦] Read 512 bytes at offset 777216000
 [2026-04-15T...][✅] Byte-range read verified
 [2026-04-15T...][ℹ️] Reading 64 bytes at tail offset 1553924032…
 [2026-04-15T...][📦] Read 64 bytes at offset 1553923968
 [2026-04-15T...][ℹ️] Stability check: repeating first 256-byte read…
 [2026-04-15T...][✅] Stability check passed — repeated reads are consistent
 [2026-04-15T...][✅] Basic local read complete

 ──────────────────────────────────────────────────────────────────────────────
*/
