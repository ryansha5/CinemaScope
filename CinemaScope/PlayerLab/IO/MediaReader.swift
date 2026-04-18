import Foundation

// MARK: - MediaReaderError

enum MediaReaderError: Error, LocalizedError {
    case notOpened
    case invalidRange(offset: Int64, length: Int, fileSize: Int64)
    case httpError(statusCode: Int)
    case byteRangesNotSupported
    case readFailed(underlying: Error)
    case fileSizeUnknown

    var errorDescription: String? {
        switch self {
        case .notOpened:
            return "MediaReader.open() has not been called"
        case .invalidRange(let offset, let length, let fileSize):
            return "Requested range \(offset)+\(length) exceeds file size \(fileSize)"
        case .httpError(let code):
            return "HTTP \(code)"
        case .byteRangesNotSupported:
            return "Server does not support byte-range requests (no Accept-Ranges header)"
        case .readFailed(let err):
            return "Read failed: \(err.localizedDescription)"
        case .fileSizeUnknown:
            return "Content-Length is unknown; byte-range seeks are not possible"
        }
    }
}

// MARK: - MediaReader
//
// Single-URL byte-level reader that works for both local files and HTTP/HTTPS
// sources.  It is intentionally simple: no caching, no prefetch, no adaptive
// logic.  Correctness and observability first.
//
// Lifecycle:
//   1. init(url:)                       — describe the source
//   2. await open()                     — resolve headers / file attributes
//   3. await read(offset:length:)       — request arbitrary byte ranges
//
// After open(), the following properties are populated:
//   • contentLength      — total byte count as Int64, or -1 if unknown
//   • contentType        — MIME type (HTTP only, nil for local files)
//   • supportsByteRanges — true if server sends Accept-Ranges: bytes OR it's local
//
// Offset type is Int64 throughout so reads past the 2 GB boundary are safe on
// all platforms, including 32-bit simulators.

final class MediaReader {

    // MARK: - Public properties (populated after open())

    let url: URL

    /// Total file/resource size in bytes.  -1 means unknown (e.g. live stream).
    private(set) var contentLength: Int64 = -1

    /// MIME type from HTTP Content-Type header.  nil for local files.
    private(set) var contentType: String? = nil

    /// True if arbitrary byte-range reads are supported.
    /// Always true for local files.  For HTTP, requires Accept-Ranges: bytes.
    private(set) var supportsByteRanges: Bool = false

    // MARK: - Private state

    private var isOpen: Bool = false
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// Persistent file handle for local files.
    /// Kept open for the lifetime of the reader to avoid per-read open/close overhead.
    private var localFileHandle: FileHandle? = nil

    // MARK: - Simple read-ahead buffer
    //
    // Caches the last read result.  When the next request falls within the
    // cached window we return immediately without hitting disk or network.
    // This is intentionally minimal — one slot, no eviction policy.
    // Purpose: avoid redundant re-reads of the same range (e.g. stability checks).

    private struct ReadCache {
        let offset: Int64
        let data: Data
        var endOffset: Int64 { offset + Int64(data.count) }

        func slice(offset: Int64, length: Int) -> Data? {
            guard offset >= self.offset, offset + Int64(length) <= endOffset else { return nil }
            let start = Int(offset - self.offset)
            return data[start ..< start + length]
        }
    }
    private var readCache: ReadCache? = nil

    // MARK: - Init

    init(url: URL) {
        self.url = url
        log(.info, "MediaReader created for: \(url.isFileURL ? url.path : url.absoluteString)")
    }

    // MARK: - Open
    //
    // Local files: stat for size, set supportsByteRanges = true.
    // HTTP:        HEAD request to resolve Content-Length, Content-Type, Accept-Ranges.

    func open() async throws {
        log(.info, "open() called")

        if url.isFileURL {
            try openLocalFile()
        } else {
            try await openRemoteURL()
        }

        isOpen = true
        log(.success, "open() complete — size: \(formatBytes(contentLength)), byteRanges: \(supportsByteRanges)")
    }

    private func openLocalFile() throws {
        do {
            // Open a persistent FileHandle so every read() call reuses it
            // rather than paying the open/close cost on every byte-range request.
            let fh = try FileHandle(forReadingFrom: url)
            localFileHandle = fh

            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? Int64 {
                contentLength      = size
                supportsByteRanges = true
                log(.info, "Local file size: \(formatBytes(size))")
            } else if let size = attrs[.size] as? Int {
                contentLength      = Int64(size)
                supportsByteRanges = true
                log(.info, "Local file size: \(formatBytes(contentLength))")
            } else {
                contentLength      = -1
                supportsByteRanges = false
                log(.warning, "Could not determine local file size")
            }
            contentType = nil
        } catch {
            log(.error, "File attribute read failed: \(error)")
            throw MediaReaderError.readFailed(underlying: error)
        }
    }

    private func openRemoteURL() async throws {
        log(.info, "Issuing HEAD to \(url.absoluteString)")

        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"

        let (_, response) = try await session.data(for: headRequest)

        guard let http = response as? HTTPURLResponse else {
            throw MediaReaderError.readFailed(underlying: URLError(.badServerResponse))
        }

        let status = http.statusCode
        log(.info, "HEAD → HTTP \(status)")
        guard (200...299).contains(status) else { throw MediaReaderError.httpError(statusCode: status) }

        // Content-Length
        if let s = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(s) {
            contentLength = n
            log(.info, "Content-Length: \(formatBytes(n))")
        } else {
            contentLength = -1
            log(.warning, "Content-Length missing or unparseable")
        }

        // Content-Type
        if let ct = http.value(forHTTPHeaderField: "Content-Type") {
            contentType = ct
            log(.info, "Content-Type: \(ct)")
        }

        // Accept-Ranges
        if let ar = http.value(forHTTPHeaderField: "Accept-Ranges") {
            supportsByteRanges = ar.lowercased().contains("bytes")
            log(.info, "Accept-Ranges: \(ar) → supportsByteRanges = \(supportsByteRanges)")
        } else {
            supportsByteRanges = false
            log(.warning, "Accept-Ranges header absent — byte-range reads may fail")
        }
    }

    // MARK: - Read
    //
    // Returns up to `length` bytes starting at `offset` (may be fewer at EOF).
    // Validates range against contentLength when known.
    // Checks the single-slot read cache before hitting disk/network.
    //
    // Per-read logging is intentionally suppressed to avoid flooding stderr when
    // thousands of small sample reads are issued during packet extraction.

    func read(offset: Int64, length: Int) async throws -> Data {
        guard isOpen else { throw MediaReaderError.notOpened }
        guard length > 0 else { return Data() }

        // Range validation
        if contentLength > 0 {
            guard offset < contentLength else {
                throw MediaReaderError.invalidRange(offset: offset, length: length, fileSize: contentLength)
            }
        }

        let clampedLength: Int = contentLength > 0
            ? Int(min(Int64(length), contentLength - offset))
            : length

        // Cache hit?
        if let cached = readCache?.slice(offset: offset, length: clampedLength) {
            return cached
        }

        let data: Data
        if url.isFileURL {
            data = try readLocalRange(offset: offset, length: clampedLength)
        } else {
            data = try await readRemoteRange(offset: offset, length: clampedLength)
        }

        if data.count != clampedLength {
            log(.warning, "Short read at offset \(offset): expected \(clampedLength), got \(data.count) — likely at EOF")
        }

        // Populate cache
        readCache = ReadCache(offset: offset, data: data)

        return data
    }

    // MARK: - Local byte-range read (persistent FileHandle)
    //
    // Uses the FileHandle opened in openLocalFile() — avoids the
    // open/seek/close overhead on every individual sample read.

    private func readLocalRange(offset: Int64, length: Int) throws -> Data {
        guard let fh = localFileHandle else {
            // Shouldn't happen after open(), but fall back gracefully.
            let fh2 = try FileHandle(forReadingFrom: url)
            defer { try? fh2.close() }
            if #available(tvOS 13.4, iOS 13.4, macOS 10.15.4, *) {
                try fh2.seek(toOffset: UInt64(offset))
            } else {
                fh2.seek(toFileOffset: UInt64(offset))
            }
            return fh2.readData(ofLength: length)
        }
        do {
            if #available(tvOS 13.4, iOS 13.4, macOS 10.15.4, *) {
                try fh.seek(toOffset: UInt64(offset))
                return fh.readData(ofLength: length)
            } else {
                fh.seek(toFileOffset: UInt64(offset))
                return fh.readData(ofLength: length)
            }
        } catch {
            log(.error, "FileHandle read failed at offset \(offset): \(error)")
            throw MediaReaderError.readFailed(underlying: error)
        }
    }

    // MARK: - HTTP byte-range read (RFC 7233)
    //
    // Range: bytes=<offset>-<offset+length-1>
    // Expected response: HTTP 206 Partial Content.
    // If the server returns 200 (ignores Range), we slice the body as a fallback —
    // but log a loud warning since this won't be viable for large files.

    private func readRemoteRange(offset: Int64, length: Int) async throws -> Data {
        let lastByte = offset + Int64(length) - 1
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(lastByte)", forHTTPHeaderField: "Range")

        log(.info, "HTTP Range: bytes=\(offset)-\(lastByte)")

        do {
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw MediaReaderError.readFailed(underlying: URLError(.badServerResponse))
            }

            let status = http.statusCode
            log(.info, "Range response: HTTP \(status), body: \(data.count) bytes")
            // Log response headers for observability
            for key in ["Content-Range", "Content-Length", "Content-Type"] {
                if let val = http.value(forHTTPHeaderField: key) {
                    log(.info, "  \(key): \(val)")
                }
            }

            switch status {
            case 206:
                return data

            case 200:
                log(.warning, "Server returned 200 instead of 206 — slicing full body (not viable for large files)")
                let start = Int(offset)
                guard data.count > start else {
                    throw MediaReaderError.invalidRange(offset: offset, length: length,
                                                        fileSize: Int64(data.count))
                }
                let end = min(start + length, data.count)
                return data[start ..< end]

            default:
                throw MediaReaderError.httpError(statusCode: status)
            }
        } catch let err as MediaReaderError {
            throw err
        } catch {
            log(.error, "Network read failed: \(error)")
            throw MediaReaderError.readFailed(underlying: error)
        }
    }

    // MARK: - Logging
    //
    // Self-contained — does NOT depend on anything in PlayerLab/Diagnostics/.
    // Format matches LabLogEntry so output looks uniform in the Xcode console.
    // Filter with "[PlayerLab/IO]" in the Xcode console search bar.

    private enum IOLogLevel: String {
        case info    = "ℹ️"
        case success = "✅"
        case warning = "⚠️"
        case error   = "❌"
        case data    = "📦"
    }

    private func log(_ level: IOLogLevel, _ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        fputs("[\(ts)][\(level.rawValue)] [PlayerLab/IO] \(message)\n", stderr)
    }

    // MARK: - Utilities

    private func formatBytes(_ count: Int64) -> String {
        if count < 0              { return "unknown" }
        if count < 1_024          { return "\(count) B" }
        if count < 1_048_576      { return String(format: "%.1f KB", Double(count) / 1_024) }
        if count < 1_073_741_824  { return String(format: "%.2f MB", Double(count) / 1_048_576) }
        return String(format: "%.2f GB", Double(count) / 1_073_741_824)
    }
}
