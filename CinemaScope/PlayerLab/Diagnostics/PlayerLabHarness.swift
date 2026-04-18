import Foundation
import CoreMedia

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

    /// Full MP4 + H.264 + VideoToolbox pipeline test.
    /// Pass a local H.264 MP4 file to drive all three sprints at once.
    func runTest(mp4 url: URL, packetCount: Int = 10) async {
        await runMP4PipelineTest(url: url, packetCount: packetCount)
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

    // MARK: - Sprint 7–9: Full pipeline test
    //
    // Drives the complete PlayerLab pipeline on a local MP4 file:
    //   1. Open with MediaReader
    //   2. Parse MP4 box structure (Sprint 7)
    //   3. Log track metadata
    //   4. Extract first N H.264 packets (Sprint 8)
    //   5. Decode with VideoToolbox, confirm frame callbacks (Sprint 9)
    //
    // Use a simple H.264 MP4 — no HEVC, no MKV, no 4K remux.
    // Call from a debug button or XCTest target.

    func runMP4PipelineTest(url: URL, packetCount: Int = 10) async {
        record(.info, "══════════════════════════════════════")
        record(.info, "MP4 Pipeline Test")
        record(.info, "File: \(url.lastPathComponent)")
        record(.info, "══════════════════════════════════════")

        // ── Step 1: Open ─────────────────────────────────────────────────────

        record(.info, "[1] Opening MediaReader…")
        let reader = MediaReader(url: url)
        do {
            try await reader.open()
            record(.success, "Opened — \(formatBytes(reader.contentLength))")
        } catch {
            record(.error, "MediaReader.open() failed: \(error.localizedDescription)")
            return
        }

        // ── Step 2: Parse MP4 box tree ────────────────────────────────────────

        record(.info, "[2] Parsing MP4 box structure…")
        let demuxer = MP4Demuxer(reader: reader)
        do {
            try await demuxer.parse()
        } catch {
            record(.error, "MP4Demuxer.parse() failed: \(error.localizedDescription)")
            return
        }

        // ── Step 3: Log track metadata ────────────────────────────────────────

        record(.info, "[3] Track summary — \(demuxer.tracks.count) track(s) found")
        for track in demuxer.tracks {
            record(.info, "  Track \(track.trackID): \(track.trackType)  " +
                   "codec=\(track.codecFourCC ?? "n/a")  " +
                   "timescale=\(track.timescale)  " +
                   "samples=\(track.sampleCount)  " +
                   "duration=\(String(format: "%.2f", track.durationSeconds))s")
            if let w = track.displayWidth, let h = track.displayHeight {
                record(.info, "    Display: \(w)×\(h)")
            }
            if let avcC = track.avcCData {
                record(.info, "    avcC: \(avcC.count) bytes (SPS+PPS present)")
                logAvcCSummary(avcC)
            }
            if let hvcC = track.hvcCData {
                record(.info, "    hvcC: \(hvcC.count) bytes (VPS+SPS+PPS present)")
            }
        }

        guard let vt = demuxer.videoTrack else {
            record(.error, "No video track found in \(url.lastPathComponent)")
            return
        }
        guard vt.isH264 else {
            record(.warning, "Video track codec is '\(vt.codecFourCC ?? "?")' — H.264 required for Sprint 9 decode test")
            return
        }
        guard let avcCData = vt.avcCData else {
            record(.error, "H.264 video track has no avcC box — cannot configure decoder")
            return
        }

        record(.success, "Video track ready: H.264  \(vt.sampleCount) samples  " +
               "\(vt.displayWidth ?? 0)×\(vt.displayHeight ?? 0)")

        // ── Step 4: Extract first N packets ──────────────────────────────────

        record(.info, "[4] Extracting first \(packetCount) H.264 packets…")
        let packets: [DemuxPacket]
        do {
            packets = try await demuxer.extractPackets(count: packetCount)
        } catch {
            record(.error, "extractPackets failed: \(error.localizedDescription)")
            return
        }

        record(.success, "Extracted \(packets.count) packet(s)")
        logPacketTable(packets)

        // ── Step 5: VideoToolbox decode proof ─────────────────────────────────

        record(.info, "[5] Configuring H264Decoder…")
        let decoder = H264Decoder()
        do {
            try decoder.configure(avcCData: avcCData)
            record(.success, "Decoder configured — nalUnitLength=\(avcCData.count > 4 ? Int(avcCData[4] & 0x03) + 1 : 4) byte(s)")
        } catch {
            record(.error, "configure(avcCData:) failed: \(error.localizedDescription)")
            return
        }

        record(.info, "[5] Submitting \(packets.count) packet(s) to VideoToolbox…")
        var submitErrors = 0
        for pkt in packets {
            do {
                try decoder.decode(packet: pkt)
            } catch {
                submitErrors += 1
                record(.warning, "  decode(packet:\(pkt.index)) error: \(error.localizedDescription)")
            }
        }

        // Wait for all async callbacks to fire
        decoder.waitForAll()

        // ── Results ───────────────────────────────────────────────────────────

        let decoded = decoder.decodedFrameCount
        let errors  = decoder.decodeErrors
        let dims    = decoder.lastFrameSize

        record(.info, "──────────────────────────────────────")
        record(decoded > 0 ? .success : .error,
               "Decoded frames: \(decoded) / \(packets.count)  " +
               "(decode errors: \(errors),  submit errors: \(submitErrors))")
        if decoded > 0 {
            record(.success, "Frame dimensions: \(Int(dims.width))×\(Int(dims.height))")
            record(.success, "🎉 Sprint 9 milestone: VideoToolbox is producing decoded frames")
        } else {
            record(.error, "No frames decoded — check avcC or packet data")
        }
        record(.info, "══════════════════════════════════════")
    }

    // MARK: - Pipeline logging helpers

    private func logAvcCSummary(_ data: Data) {
        guard data.count >= 7 else { return }
        let profile    = data[1]
        let level      = data[3]
        let nalLen     = Int(data[4] & 0x03) + 1
        let numSPS     = Int(data[5] & 0x1F)
        record(.data, "    avcC: profile=\(profile) level=\(level) NAL-len=\(nalLen) SPS-count=\(numSPS)")
    }

    private func logPacketTable(_ packets: [DemuxPacket]) {
        let header = String(format: "  %-5@  %-8@  %-10@  %-10@  %-7@  %@",
                            "idx", "bytes", "pts(s)", "dts(s)", "key", "offset")
        record(.data, header)
        for pkt in packets.prefix(10) {
            let pts    = pkt.pts.seconds.isNaN ? 0 : pkt.pts.seconds
            let dts    = pkt.dts.seconds.isNaN ? 0 : pkt.dts.seconds
            let keyStr = pkt.isKeyframe ? "KEY" : "-"
            let row    = String(format: "  %-5d  %-8d  %-10.4f  %-10.4f  %-7@  %lld",
                                pkt.index, pkt.data.count,
                                pts, dts,
                                keyStr,
                                pkt.byteOffset)
            record(.data, row)
        }
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
   // IO-only test (Sprints 4-6)
   Button("Run PlayerLab IO Test") {
       Task { @MainActor in
           let h = PlayerLabHarness()
           let local = URL(fileURLWithPath: "/path/to/test.mkv")
           await h.runTest(url: local)
           print(h.formattedLog)
       }
   }

   // Full pipeline test (Sprints 7-9) — use a simple H.264 MP4
   Button("Run MP4 Pipeline Test") {
       Task { @MainActor in
           let h = PlayerLabHarness()
           let mp4 = URL(fileURLWithPath: "/path/to/sample.mp4")
           await h.runTest(mp4: mp4, packetCount: 10)
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
