import Foundation

// MARK: - LabLogEntry
//
// Structured log entry used by PlayerLabHarness.  MediaReader has its own
// internal IOLogLevel so it does not depend on this type (IO → Diagnostics
// dependency would be backwards).

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

// MARK: - PlayerLabHarness
//
// Standalone test driver for the PlayerLab subsystem.
//
// Design goals:
//   • Zero dependency on main-app playback UI or AVPlayer
//   • Every action logged in full: URL, byte counts, errors, state transitions
//   • `log` array accumulates entries — inspect programmatically from XCTest
//   • All public methods are async — call from Task, test case, or debug button
//
// Quick start:
//
//   let h = await PlayerLabHarness()
//   await h.runTest(url: URL(fileURLWithPath: "/path/to/file.mkv"))
//   print(h.formattedLog)
//
// See the "HOW TO RUN" section at the bottom of this file for full instructions.

@MainActor
final class PlayerLabHarness {

    // MARK: - State

    let engine = PlayerLabEngine()
    private(set) var log: [LabLogEntry] = []

    // MARK: - Init

    init() {
        record(.info, "PlayerLabHarness initialized")
        record(.info, "Engine state: \(engine.playbackState)")
    }

    // MARK: - Unified entry point (Sprint 4)
    //
    // Dispatches to the right test based on whether the URL is local or remote.
    // This is the primary surface for driving the harness.

    func runTest(url: URL) async {
        record(.info, "══════════════════════════════════════")
        record(.info, "runTest(url:) — \(url.isFileURL ? "LOCAL" : "REMOTE")")
        record(.info, "URL: \(url.isFileURL ? url.path : url.absoluteString)")
        record(.info, "══════════════════════════════════════")

        runEngineStateCycle()

        if url.isFileURL {
            await runFileReadValidation(url: url)
        } else {
            await runRemoteReadValidation(url: url)
        }
    }

    // MARK: - Engine state cycle
    //
    // Exercises PlayerLabEngine through a full lifecycle with no real media.
    // Used to verify the protocol surface before touching IO.

    func runEngineStateCycle() {
        record(.info, "─── Engine State Cycle ───")

        let dummy = URL(string: "playerlab://test/dummy.mkv")!

        record(.info, "setPlaybackContext(scopeUIEnabled: true, serverURL: '', itemId: 'test-01')")
        engine.setPlaybackContext(scopeUIEnabled: true, serverURL: "", itemId: "test-01")
        record(.info, "  scopeUIEnabled = \(engine.scopeUIEnabled)")

        record(.info, "load(url: \(dummy))")
        engine.load(url: dummy, startTicks: 0)
        record(.info, "  state → \(engine.playbackState)")

        record(.info, "play()")
        engine.play()
        record(.info, "  state → \(engine.playbackState)")

        record(.info, "pause()")
        engine.pause()
        record(.info, "  state → \(engine.playbackState)")

        record(.info, "seek(to: 0.5)")
        engine.seek(to: 0.5)
        record(.info, "  currentTime = \(engine.currentTime), duration = \(engine.duration)")

        record(.info, "stop()")
        engine.stop()
        record(.info, "  state → \(engine.playbackState)")
        record(.info, "  currentTime = \(engine.currentTime), duration = \(engine.duration)")

        record(.success, "Engine state cycle complete")
    }

    // MARK: - Sprint 6: Local file read validation
    //
    // Tests:
    //   1. Open + stat
    //   2. First 1 KB (magic bytes / container detection)
    //   3. Mid-file 512-byte range
    //   4. Last 64 bytes (tail)
    //   5. Stability: repeat the first read, compare byte-for-byte

    func runFileReadValidation(url: URL) async {
        record(.info, "─── Local File Read Validation ───")
        record(.info, "Path: \(url.path)")

        let reader = MediaReader(url: url)

        // ── Step 1: Open ──────────────────────────────────────────────────────

        record(.info, "[1/5] Opening reader…")
        do {
            try await reader.open()
            record(.success, "Opened. Size: \(formatBytes(reader.contentLength))")
            record(.info, "  supportsByteRanges: \(reader.supportsByteRanges)")
        } catch {
            record(.error, "Open failed: \(error.localizedDescription)")
            return
        }

        // ── Step 2: First 1 KB ────────────────────────────────────────────────

        record(.info, "[2/5] Reading first 1 KB…")
        var firstRead = Data()
        do {
            firstRead = try await reader.read(offset: 0, length: 1024)
            record(.data, "  Got \(firstRead.count) bytes from offset 0")
            record(.data, "  First 16 bytes (hex): \(hexString(firstRead.prefix(16)))")
            detectContainer(firstRead)
        } catch {
            record(.error, "First read failed: \(error.localizedDescription)")
        }

        // ── Step 3: Mid-file 512 bytes ────────────────────────────────────────

        let midOffset = reader.contentLength / 2
        if midOffset > 1024 {
            record(.info, "[3/5] Reading 512 bytes at mid-file offset \(midOffset)…")
            do {
                let chunk = try await reader.read(offset: midOffset, length: 512)
                record(.data, "  Got \(chunk.count) bytes at offset \(midOffset)")
                record(.success, "  Mid-file byte-range read OK")
            } catch {
                record(.error, "  Mid-file read failed: \(error.localizedDescription)")
            }
        } else {
            record(.warning, "[3/5] File too small for mid-file test (size: \(formatBytes(reader.contentLength)))")
        }

        // ── Step 4: Tail 64 bytes ─────────────────────────────────────────────

        let tailOffset = max(0, reader.contentLength - 64)
        record(.info, "[4/5] Reading 64 bytes at tail offset \(tailOffset)…")
        do {
            let tail = try await reader.read(offset: tailOffset, length: 64)
            record(.data, "  Got \(tail.count) bytes at offset \(tailOffset)")
        } catch {
            record(.error, "  Tail read failed: \(error.localizedDescription)")
        }

        // ── Step 5: Stability ─────────────────────────────────────────────────

        record(.info, "[5/5] Stability check — repeating first 1 KB read…")
        guard !firstRead.isEmpty else {
            record(.warning, "  Skipping stability check (first read produced no data)")
            return
        }
        do {
            let repeat1 = try await reader.read(offset: 0, length: 1024)
            let repeat2 = try await reader.read(offset: 0, length: 1024)
            let allMatch = repeat1 == firstRead && repeat2 == firstRead
            if allMatch {
                record(.success, "  Stability check passed — 3 reads of same range are identical")
            } else {
                record(.warning, "  Stability check FAILED — repeated reads returned different data")
            }
        } catch {
            record(.error, "  Stability read failed: \(error.localizedDescription)")
        }

        record(.success, "Local file read validation complete")
    }

    // MARK: - Sprint 6: Remote read validation
    //
    // Same test pattern as local: open → header → mid → tail → stability.
    // Adds HTTP header logging (Content-Type, Content-Length, Accept-Ranges).

    func runRemoteReadValidation(url: URL) async {
        record(.info, "─── Remote Read Validation ───")
        record(.info, "URL: \(url.absoluteString)")

        let reader = MediaReader(url: url)

        // ── Step 1: Open (HEAD request) ───────────────────────────────────────

        record(.info, "[1/5] Opening remote reader (HEAD)…")
        do {
            try await reader.open()
            record(.success, "Opened.")
            record(.info, "  Content-Length:      \(formatBytes(reader.contentLength))")
            record(.info, "  Content-Type:        \(reader.contentType ?? "(unknown)")")
            record(.info, "  supportsByteRanges:  \(reader.supportsByteRanges)")

            if !reader.supportsByteRanges {
                record(.warning, "Server does not advertise Accept-Ranges: bytes — reads may degrade to full GET + slice")
            }
        } catch {
            record(.error, "Open failed: \(error.localizedDescription)")
            return
        }

        // ── Step 2: First 1 KB ────────────────────────────────────────────────

        record(.info, "[2/5] Reading first 1 KB via HTTP Range…")
        var firstRead = Data()
        do {
            firstRead = try await reader.read(offset: 0, length: 1024)
            record(.data, "  Got \(firstRead.count) bytes from offset 0")
            record(.data, "  First 16 bytes (hex): \(hexString(firstRead.prefix(16)))")
            detectContainer(firstRead)
        } catch {
            record(.error, "  First read failed: \(error.localizedDescription)")
        }

        // ── Step 3: Mid-file 512 bytes ────────────────────────────────────────

        let midOffset = reader.contentLength / 2
        if midOffset > 1024 {
            record(.info, "[3/5] Reading 512 bytes at mid-file offset \(midOffset)…")
            do {
                let chunk = try await reader.read(offset: midOffset, length: 512)
                record(.data, "  Got \(chunk.count) bytes at offset \(midOffset)")
                record(.success, "  Mid-file HTTP range read OK")
            } catch {
                record(.error, "  Mid-file read failed: \(error.localizedDescription)")
            }
        } else {
            record(.warning, "[3/5] Content-Length unknown or too small for mid-file test")
        }

        // ── Step 4: Tail 64 bytes ─────────────────────────────────────────────

        if reader.contentLength > 0 {
            let tailOffset = max(0, reader.contentLength - 64)
            record(.info, "[4/5] Reading 64 bytes at tail offset \(tailOffset)…")
            do {
                let tail = try await reader.read(offset: tailOffset, length: 64)
                record(.data, "  Got \(tail.count) bytes at offset \(tailOffset)")
            } catch {
                record(.error, "  Tail read failed: \(error.localizedDescription)")
            }
        } else {
            record(.warning, "[4/5] Skipping tail read — content length unknown")
        }

        // ── Step 5: Stability ─────────────────────────────────────────────────

        record(.info, "[5/5] Stability check — repeating first 1 KB read…")
        guard !firstRead.isEmpty else {
            record(.warning, "  Skipping stability check (first read produced no data)")
            return
        }
        do {
            let repeat1 = try await reader.read(offset: 0, length: 1024)
            let repeat2 = try await reader.read(offset: 0, length: 1024)
            let allMatch = repeat1 == firstRead && repeat2 == firstRead
            if allMatch {
                record(.success, "  Stability check passed — 3 reads of same range are identical")
            } else {
                record(.warning, "  Stability check FAILED — repeated reads returned different data")
            }
        } catch {
            record(.error, "  Stability read failed: \(error.localizedDescription)")
        }

        record(.success, "Remote read validation complete")
    }

    // MARK: - Log API

    func record(_ level: LabLogEntry.Level, _ message: String) {
        let entry = LabLogEntry(timestamp: Date(), level: level, message: message)
        log.append(entry)
        fputs(entry.formatted + "\n", stderr)
    }

    var formattedLog: String {
        log.map(\.formatted).joined(separator: "\n")
    }

    func clearLog() {
        log.removeAll()
        record(.info, "Log cleared")
    }

    // MARK: - Utilities

    private func hexString<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func formatBytes(_ count: Int64) -> String {
        if count < 0             { return "unknown" }
        if count < 1_024         { return "\(count) B" }
        if count < 1_048_576     { return String(format: "%.1f KB", Double(count) / 1_024) }
        if count < 1_073_741_824 { return String(format: "%.2f MB", Double(count) / 1_048_576) }
        return String(format: "%.2f GB", Double(count) / 1_073_741_824)
    }

    private func detectContainer(_ data: Data) {
        let bytes = Array(data.prefix(12))
        guard bytes.count >= 4 else { return }

        let label: String
        if bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 {
            label = "EBML/Matroska (MKV or WebM)"
        } else if bytes.count >= 8, String(bytes: bytes[4...7], encoding: .ascii) == "ftyp" {
            label = "ISO Base Media (MP4/MOV/M4V)"
        } else if bytes[0] == 0x47 {
            label = "MPEG-TS"
        } else {
            let raw = bytes.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
            label = "unrecognized [\(raw)]"
        }
        record(.info, "  Container hint: \(label)")
    }
}

/*
 ──────────────────────────────────────────────────────────────────────────────
 HOW TO RUN LOCALLY
 ──────────────────────────────────────────────────────────────────────────────

 Option A — Debug button in SettingsView (no extra target needed)
 ─────────────────────────────────────────────────────────────────
   #if DEBUG
   Button("Run PlayerLab IO Test") {
       Task { @MainActor in
           let h = PlayerLabHarness()

           // Local file:
           let local = URL(fileURLWithPath: "/path/to/test.mkv")
           await h.runTest(url: local)

           // Remote URL:
           // let remote = URL(string: "https://example.com/sample.mp4")!
           // await h.runTest(url: remote)

           print(h.formattedLog)
       }
   }
   #endif

 Option B — XCTest target (PlayerLabTests)
 ──────────────────────────────────────────
   class PlayerLabIOTests: XCTestCase {
       func testLocalRead() async throws {
           let h = await PlayerLabHarness()
           let url = Bundle.module.url(forResource: "sample", withExtension: "mkv")!
           await h.runTest(url: url)
           XCTAssertTrue(h.log.allSatisfy { $0.level != .error })
       }
   }

 ──────────────────────────────────────────────────────────────────────────────
 EXPECTED CONSOLE OUTPUT (local MKV, ~1.5 GB)
 ──────────────────────────────────────────────────────────────────────────────

 [T][ℹ️] ══════════════════════════════════════
 [T][ℹ️] runTest(url:) — LOCAL
 [T][ℹ️] URL: /Users/shane/Downloads/test.mkv
 [T][ℹ️] ══════════════════════════════════════
 [T][ℹ️] ─── Engine State Cycle ───
 ...
 [T][✅] Engine state cycle complete
 [T][ℹ️] ─── Local File Read Validation ───
 [T][ℹ️] Path: /Users/shane/Downloads/test.mkv
 [T][ℹ️] [1/5] Opening reader…
 [T][✅] [PlayerLab/IO] open() complete — size: 1.45 GB, byteRanges: true
 [T][✅] Opened. Size: 1.45 GB
 [T][ℹ️]   supportsByteRanges: true
 [T][ℹ️] [2/5] Reading first 1 KB…
 [T][📦]   Got 1024 bytes from offset 0
 [T][📦]   First 16 bytes (hex): 1a 45 df a3 01 00 00 00 00 00 00 1f 42 86 81 01
 [T][ℹ️]   Container hint: EBML/Matroska (MKV or WebM)
 [T][ℹ️] [3/5] Reading 512 bytes at mid-file offset 778268672…
 [T][📦]   Got 512 bytes at offset 778268672
 [T][✅]   Mid-file byte-range read OK
 [T][ℹ️] [4/5] Reading 64 bytes at tail offset 1556537280…
 [T][📦]   Got 64 bytes at offset 1556537280
 [T][ℹ️] [5/5] Stability check — repeating first 1 KB read…
 [T][✅]   Stability check passed — 3 reads of same range are identical
 [T][✅] Local file read validation complete

 ──────────────────────────────────────────────────────────────────────────────
 EXPECTED CONSOLE OUTPUT (remote MP4 with byte-range support)
 ──────────────────────────────────────────────────────────────────────────────

 [T][ℹ️] [1/5] Opening remote reader (HEAD)…
 [T][ℹ️] [PlayerLab/IO] HEAD → HTTP 200
 [T][ℹ️] [PlayerLab/IO] Content-Length: 24.50 MB
 [T][ℹ️] [PlayerLab/IO] Content-Type: video/mp4
 [T][ℹ️] [PlayerLab/IO] Accept-Ranges: bytes → supportsByteRanges = true
 [T][✅] Opened.
 [T][ℹ️]   Content-Length:      24.50 MB
 [T][ℹ️]   Content-Type:        video/mp4
 [T][ℹ️]   supportsByteRanges:  true
 [T][ℹ️] [2/5] Reading first 1 KB via HTTP Range…
 [T][ℹ️] [PlayerLab/IO] HTTP Range: bytes=0-1023
 [T][ℹ️] [PlayerLab/IO] Range response: HTTP 206, body: 1024 bytes
 [T][📦]   Got 1024 bytes from offset 0
 [T][ℹ️]   Container hint: ISO Base Media (MP4/MOV/M4V)
 ...
 [T][✅] Remote read validation complete

 ──────────────────────────────────────────────────────────────────────────────
*/
