// MARK: - PlayerLab / Demux / MKV / MKVParser
//
// Sprint 20 — EBML / Matroska low-level parser
//
// Reads EBML-encoded Matroska (.mkv) files using MediaReader for byte-range IO.
//
// Scope:
//   • EBML header validation
//   • Variable-length integer (VINT) decoding for element IDs and sizes
//   • Sequential element scanning — returns (id, payloadOffset, payloadSize) tuples
//   • No state; pure parsing primitives used by MKVDemuxer
//
// EBML encoding recap:
//   Every element = [ID vint][Size vint][payload]
//   VINT width is determined by the leading set bit:
//     1xxxxxxx → 1 byte  (value = byte & 0x7F)
//     01xxxxxx → 2 bytes (value = (byte & 0x3F) << 8 | next)
//     001xxxxx → 3 bytes … etc, up to 8 bytes
//   A size whose mantissa is all 1-bits means "unknown / streaming length".
//
// NOT production-ready. Debug / lab use only.

import Foundation

// MARK: - Error

enum MKVParseError: Error, LocalizedError {
    case readFailed(underlying: Error)
    case notEBML
    case notMatroska(docType: String)
    case segmentNotFound
    case vintOverflow
    case unexpectedEOF

    var errorDescription: String? {
        switch self {
        case .readFailed(let e):       return "Read failed: \(e.localizedDescription)"
        case .notEBML:                 return "File does not start with an EBML header"
        case .notMatroska(let dt):     return "DocType is '\(dt)', expected 'matroska' or 'webm'"
        case .segmentNotFound:         return "No Segment element found"
        case .vintOverflow:            return "VINT longer than 8 bytes"
        case .unexpectedEOF:           return "Unexpected end of file"
        }
    }
}

// MARK: - EBML Element IDs (hex)

enum EBMLID: UInt64 {
    // Top-level EBML
    case ebmlHeader          = 0x1A45DFA3
    case docType             = 0x4282
    case docTypeVersion      = 0x4287
    // Segment and children
    case segment             = 0x18538067
    case seekHead            = 0x114D9B74
    case info                = 0x1549A966
    case timecodeScale       = 0x2AD7B1      // nanoseconds per tick (default 1 000 000)
    case duration            = 0x4489
    case tracks              = 0x1654AE6B
    case trackEntry          = 0xAE
    case trackNumber         = 0xD7
    case trackType           = 0x83          // 1=video 2=audio
    case codecID             = 0x86
    case codecPrivate        = 0x63A2
    case video               = 0xE0
    case pixelWidth          = 0xB0
    case pixelHeight         = 0xBA
    case audio               = 0xE1
    case samplingFrequency   = 0xB5
    case channels            = 0x9F
    // Cluster
    case cluster             = 0x1F43B675
    case clusterTimestamp    = 0xE7          // cluster base timecode
    case simpleBlock         = 0xA3
    case blockGroup          = 0xA0
    case block               = 0xA1
    case referenceBlock      = 0xFB          // presence = non-keyframe
    // BlockAdditions — used by Dolby Vision Profile 7 to carry the Enhancement Layer (EL)
    // alongside the Base Layer (BL) in the same BlockGroup.
    case blockAdditions      = 0x75A1        // container
    case blockMore           = 0xA6          // one addition entry
    case blockAddID          = 0xEE          // addition type ID (1 = DV EL)
    case blockAdditional     = 0xA5          // raw EL bytes
    // Track entry flags / metadata (Sprint 23 / 26)
    case flagDefault         = 0x88          // 1 = default track
    case flagForced          = 0x55AA        // Sprint 26: 1 = forced subtitle
    case language            = 0x22B59C      // ISO 639-2 language code
    // Block timing (Sprint 26: subtitle end times)
    case blockDuration       = 0x9B          // duration in cluster timescale ticks
    // Chapters (Sprint 27)
    case chapters            = 0x1043A770    // top-level Chapters element in Segment
    case editionEntry        = 0x45B9        // an edition (group of chapters)
    case chapterAtom         = 0xB6          // one chapter entry
    case chapterTimeStart    = 0x91          // start time in nanoseconds
    case chapterTimeEnd      = 0x92          // end time in nanoseconds (optional)
    case chapterDisplay      = 0x80          // display info sub-element
    case chapString          = 0x85          // chapter title string
    case chapLanguage        = 0x437C        // chapter title language
    // Housekeeping
    case void                = 0xEC
    case crc32               = 0xBF
}

// MARK: - EBMLElement

struct EBMLElement {
    let id:            UInt64
    let payloadOffset: Int64   // file offset of first payload byte
    let payloadSize:   Int64   // -1 = unknown / streaming
    var knownID:       EBMLID? { EBMLID(rawValue: id) }
    var headerSize: Int64 {
        // We don't store it directly; callers use nextElementOffset.
        payloadOffset   // indirect — see MKVParser.scan()
    }
    /// File offset of the byte immediately after this element's payload.
    /// Only valid when payloadSize >= 0.
    func nextOffset() -> Int64 {
        payloadSize >= 0 ? payloadOffset + payloadSize : payloadOffset
    }
}

// MARK: - MKVParser

/// Low-level EBML parser that wraps an EBMLBufferedReader.
/// Provides two main operations:
///   • readVINT(at:)          — decode one variable-length integer
///   • nextElement(at:limit:) — decode the element at `at`, return header+payload info
///
/// Thread safety: not thread-safe; all calls must be from the same async context.
///
/// Sprint 43: reader is now EBMLBufferedReader (512 KB window) rather than
/// MediaReader.  All small VINT / element-header reads are served from the
/// in-memory window; HTTP Range requests are issued only on window misses.

final class MKVParser {

    let reader: EBMLBufferedReader

    init(reader: EBMLBufferedReader) {
        self.reader = reader
    }

    // MARK: - VINT Decode
    //
    // Returns (value, bytesConsumed).
    // For sizes: allOnes value means "unknown length" — returned as -1 by callers.

    func readVINT(at offset: Int64) async throws -> (value: UInt64, width: Int) {
        let first: UInt8
        do {
            // Sprint 43: readBytes(at:length:) is served from the 512 KB window —
            // no HTTP round-trip unless the window needs refilling.
            let d = try await reader.readBytes(at: offset, length: 1)
            guard let byte = d.first else { throw MKVParseError.unexpectedEOF }
            first = byte
        } catch let e as MKVParseError {
            throw e
        } catch {
            throw MKVParseError.readFailed(underlying: error)
        }

        // Count leading zeros to determine byte width
        var width = 0
        var mask:  UInt8 = 0x80
        while mask > 0 {
            width += 1
            if first & mask != 0 { break }
            mask >>= 1
        }
        guard width <= 8 else { throw MKVParseError.vintOverflow }
        if width == 1 {
            return (UInt64(first & ~mask), 1)
        }

        // Read remaining bytes — almost always within the existing window.
        do {
            let rest = try await reader.readBytes(at: offset + 1, length: width - 1)
            var value = UInt64(first & ~mask)
            for i in 0..<(width - 1) {
                value = (value << 8) | UInt64(rest[rest.index(rest.startIndex, offsetBy: i)])
            }
            return (value, width)
        } catch {
            throw MKVParseError.readFailed(underlying: error)
        }
    }

    // MARK: - Element Header Decode
    //
    // IDs are VINTs but their marker bit is NOT stripped (IDs are opaque).
    // Sizes ARE stripped (they encode the payload byte count).

    func nextElement(at offset: Int64, limit: Int64) async throws -> (element: EBMLElement, headerBytes: Int)? {
        guard offset < limit else { return nil }

        // 1. Read ID (VINT, marker bit retained)
        // Sprint 43: served from 512 KB window — no HTTP unless window misses.
        let first: UInt8
        do {
            let d = try await reader.readBytes(at: offset, length: 1)
            guard let byte = d.first else { return nil }
            first = byte
        } catch { return nil }

        var idWidth = 0
        var mask: UInt8 = 0x80
        while mask > 0 {
            idWidth += 1
            if first & mask != 0 { break }
            mask >>= 1
        }
        guard idWidth <= 4, idWidth >= 1 else { return nil }

        var rawID = UInt64(first)
        if idWidth > 1 {
            guard let rest = try? await reader.readBytes(at: offset + 1, length: idWidth - 1) else { return nil }
            for i in 0..<(idWidth - 1) {
                rawID = (rawID << 8) | UInt64(rest[rest.index(rest.startIndex, offsetBy: i)])
            }
        }

        // 2. Read Size VINT (marker bit stripped; all-ones = unknown)
        let sizeOffset = offset + Int64(idWidth)
        guard let (sizeVal, sizeWidth) = try? await readVINT(at: sizeOffset) else { return nil }

        // Detect "unknown size" (all mantissa bits set)
        let unknownSize: UInt64
        switch sizeWidth {
        case 1: unknownSize = 0x7F
        case 2: unknownSize = 0x3FFF
        case 3: unknownSize = 0x1FFFFF
        case 4: unknownSize = 0x0FFFFFFF
        case 5: unknownSize = 0x07FFFFFFFF
        case 6: unknownSize = 0x03FFFFFFFFFF
        case 7: unknownSize = 0x01FFFFFFFFFFFF
        default: unknownSize = 0x00FFFFFFFFFFFFFF
        }
        let payloadSize: Int64 = (sizeVal == unknownSize) ? -1 : Int64(sizeVal)

        let headerBytes = idWidth + sizeWidth
        let payloadOffset = offset + Int64(headerBytes)

        let element = EBMLElement(id: rawID,
                                  payloadOffset: payloadOffset,
                                  payloadSize: payloadSize)
        return (element, headerBytes)
    }

    // MARK: - Convenience: read small payload as bytes

    func readPayload(_ element: EBMLElement, maxBytes: Int = 256) async throws -> Data {
        guard element.payloadSize > 0 else { return Data() }
        let len = Int(min(Int64(maxBytes), element.payloadSize))
        do {
            // Sprint 43: served from 512 KB window for small payloads.
            return try await reader.readBytes(at: element.payloadOffset, length: len)
        } catch {
            throw MKVParseError.readFailed(underlying: error)
        }
    }

    // MARK: - Unsigned integer payload

    func readUInt(_ element: EBMLElement) async throws -> UInt64 {
        guard element.payloadSize > 0, element.payloadSize <= 8 else { return 0 }
        let data = try await readPayload(element, maxBytes: 8)
        var value: UInt64 = 0
        for byte in data { value = (value << 8) | UInt64(byte) }
        return value
    }

    // MARK: - Float payload (4 or 8 bytes, big-endian IEEE 754)

    func readFloat(_ element: EBMLElement) async throws -> Double {
        guard element.payloadSize == 4 || element.payloadSize == 8 else { return 0 }
        let data = try await readPayload(element, maxBytes: 8)
        if element.payloadSize == 4 {
            var bits: UInt32 = 0
            for byte in data { bits = (bits << 8) | UInt32(byte) }
            return Double(Float(bitPattern: bits))
        } else {
            var bits: UInt64 = 0
            for byte in data { bits = (bits << 8) | UInt64(byte) }
            return Double(bitPattern: bits)
        }
    }

    // MARK: - String payload

    func readString(_ element: EBMLElement) async throws -> String {
        let data = try await readPayload(element, maxBytes: 256)
        return String(data: data, encoding: .ascii)?
            .trimmingCharacters(in: .controlCharacters) ?? ""
    }

    // MARK: - EBML Header Validation

    /// Reads the EBML header, validates DocType is matroska/webm.
    /// Returns the file offset immediately after the EBML header element.
    func validateEBMLHeader() async throws -> Int64 {
        guard let (headerElem, headerBytes) = try await nextElement(at: 0, limit: reader.contentLength)
        else { throw MKVParseError.notEBML }

        guard headerElem.knownID == .ebmlHeader else { throw MKVParseError.notEBML }

        // Scan inside the EBML header for DocType
        var docType = "matroska"
        var cursor  = headerElem.payloadOffset
        let end     = headerElem.payloadOffset + (headerElem.payloadSize > 0 ? headerElem.payloadSize : 64)
        while cursor < end {
            guard let (child, chBytes) = try? await nextElement(at: cursor, limit: end) else { break }
            if child.knownID == .docType {
                docType = (try? await readString(child)) ?? docType
            }
            let totalSize = Int64(chBytes) + (child.payloadSize >= 0 ? child.payloadSize : 0)
            cursor += max(1, totalSize)
        }

        guard docType == "matroska" || docType == "webm" else {
            throw MKVParseError.notMatroska(docType: docType)
        }

        return headerElem.payloadOffset + max(0, headerElem.payloadSize)
    }
}
