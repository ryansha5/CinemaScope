// MARK: - PlayerLab / IO / EBMLBufferedReader
//
// Sprint 43 — Buffered byte-range reader for EBML / Matroska parsing.
//
// Problem solved:
//   MKVParser.readVINT() issues a 1-byte HTTP Range request to determine
//   the width of each variable-length integer, then a second request for
//   the remaining bytes.  nextElement() compounds this — it makes 2–4
//   separate HTTP calls per EBML element header.  For a typical MKV file
//   the EBML header + Segment/Info/Tracks region requires 200–400 tiny
//   HTTP round-trips before the demuxer can start indexing clusters.
//   Over a 10 ms average RTT link this adds 2–4 seconds of pure latency
//   *before* a single video frame is enqueued.
//
// Fix:
//   Maintain a 512 KB sliding window over MediaReader.  Reads that fall
//   entirely within the window are served from memory with no network I/O.
//   A new HTTP Range request is issued only when the requested range starts
//   outside the current window.
//
//   Typical result:
//     • EBML header + Segment header + Info + Tracks:  1 HTTP request
//       (was 200–400).
//     • Per-cluster element parsing:  1 request per ~15 frames instead of
//       1 per element header.
//     • 120-second initial index for an H.265 / TrueHD MKV: ~120 fills
//       ≈ 1–2 seconds (was unbounded / user-cancelled after 0.3 s).
//
// Design:
//   • Pure IO helper — no EBML knowledge, no state except the byte window.
//   • MKVParser's `reader` property is now an EBMLBufferedReader instead
//     of a MediaReader.  MKVDemuxer holds both types: the buffered reader
//     for small sequential header reads; the raw MediaReader for the large
//     batched packet-extraction reads (which already coalesce contiguous
//     ranges and bypass this buffer intentionally).
//
// NOT production-ready.  Debug / lab use only.

import Foundation

// MARK: - EBMLBufferedReader

final class EBMLBufferedReader {

    // MARK: - Configuration

    /// Bytes fetched per HTTP Range request during parsing.
    ///
    /// 512 KB covers ~15 average H.265 frames (33 KB each) per fill.
    /// Large enough to make sequential EBML parsing cheap; small enough
    /// that we don't waste bandwidth on content where PlayerLab falls back.
    static let chunkSize: Int = 512 * 1024

    // MARK: - Public properties (delegate to underlying reader)

    var contentLength: Int64 { reader.contentLength }
    var url:           URL   { reader.url }

    /// Number of HTTP Range requests issued so far (each = one buffer fill).
    /// Exposed for startup-timing diagnostics.
    private(set) var fillCount: Int = 0

    // MARK: - Private state

    private let reader: MediaReader

    /// File offset of `buffer[0]`.  -1 when the buffer is empty.
    private var windowStart: Int64 = -1
    private var window:      Data  = Data()

    // MARK: - Init

    init(reader: MediaReader) {
        self.reader = reader
    }

    // MARK: - Core read API

    /// Returns exactly `length` bytes starting at `offset`.
    ///
    /// Serves from the internal window when possible.  Refills the window
    /// (one HTTP Range request) when the requested range falls outside it.
    /// If the refill still does not cover the full request (e.g. near EOF),
    /// falls back to a direct `reader.read()` for the remainder.
    func readBytes(at offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }

        // Fast path: request is entirely within the current window.
        if let slice = windowSlice(at: offset, length: length) {
            return slice
        }

        // Refill the window starting at `offset`.
        try await refillWindow(at: offset)

        // Second attempt: post-fill.
        if let slice = windowSlice(at: offset, length: length) {
            return slice
        }

        // Fallback: direct read handles EOF edge cases (short content,
        // near-end-of-file requests that underflow the requested length).
        return try await reader.read(offset: offset, length: length)
    }

    /// Reads a single byte at `offset`.
    func readByte(at offset: Int64) async throws -> UInt8 {
        let data = try await readBytes(at: offset, length: 1)
        guard let byte = data.first else {
            throw MediaReaderError.readFailed(
                underlying: NSError(domain: "EBMLBufferedReader",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Empty read at offset \(offset)"]))
        }
        return byte
    }

    // MARK: - Window management

    private func windowSlice(at offset: Int64, length: Int) -> Data? {
        guard windowStart >= 0, !window.isEmpty else { return nil }
        let windowEnd = windowStart + Int64(window.count)
        guard offset >= windowStart,
              offset + Int64(length) <= windowEnd else { return nil }
        let start = Int(offset - windowStart)
        return window[start ..< start + length]
    }

    private func refillWindow(at offset: Int64) async throws {
        let fileSize = reader.contentLength
        let fetchLen: Int
        if fileSize > 0 {
            let remaining = fileSize - offset
            guard remaining > 0 else { return }
            fetchLen = Int(min(Int64(Self.chunkSize), remaining))
        } else {
            fetchLen = Self.chunkSize
        }

        let data = try await reader.read(offset: offset, length: fetchLen)
        windowStart = offset
        window      = data
        fillCount  += 1

        // Log every fill so startup timing can be correlated against HTTP traffic.
        // Filter "[EBMLBuf]" in the console to see the fill log.
        log("fill #\(fillCount) offset=\(formatBytes(offset)) size=\(formatBytes(Int64(data.count)))")
    }

    // MARK: - Logging

    private func log(_ msg: String) {
        fputs("[EBMLBuf] \(msg)\n", stderr)
    }

    // MARK: - Formatting helpers

    private func formatBytes(_ n: Int64) -> String {
        if n < 0             { return "?" }
        if n < 1_024         { return "\(n)B" }
        if n < 1_048_576     { return String(format: "%.1fKB", Double(n) / 1_024) }
        if n < 1_073_741_824 { return String(format: "%.2fMB", Double(n) / 1_048_576) }
        return String(format: "%.2fGB", Double(n) / 1_073_741_824)
    }
}
