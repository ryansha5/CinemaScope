// MARK: - PlayerLab / Demux / MP4 / MP4Box
//
// Parsed ISOBMFF / MP4 box header.
// Does not load payload — callers use MediaReader to read what they need.

import Foundation

// MARK: - Box Header

struct MP4Box {

    /// Four-character box type FourCC (e.g. "moov", "trak", "avcC").
    let type:        String

    /// File byte offset of the first byte of this box (the size field).
    let fileOffset:  Int64

    /// Byte length of the box header: 8 for normal boxes, 16 for extended-size.
    let headerSize:  Int

    /// Total byte size of this box including header.
    let totalSize:   Int64

    var payloadOffset: Int64 { fileOffset + Int64(headerSize) }
    var payloadSize:   Int64 { totalSize  - Int64(headerSize) }

    // MARK: - Container classification

    /// Container boxes whose payload is a sequence of child boxes.
    /// These are recursed into during box-tree walking.
    static let containerTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl",
        "dinf", "edts", "udta", "moof", "traf", "mvex"
    ]

    var isContainer: Bool { MP4Box.containerTypes.contains(type) }
}

// MARK: - Big-endian read helpers (file-private, used by MP4Demuxer)

extension Data {

    func mp4UInt8(at i: Int) -> UInt8 {
        self[index(startIndex, offsetBy: i)]
    }

    func mp4UInt16BE(at i: Int) -> UInt16 {
        UInt16(mp4UInt8(at: i)) << 8 | UInt16(mp4UInt8(at: i + 1))
    }

    func mp4UInt32BE(at i: Int) -> UInt32 {
        UInt32(mp4UInt8(at: i))     << 24 |
        UInt32(mp4UInt8(at: i + 1)) << 16 |
        UInt32(mp4UInt8(at: i + 2)) <<  8 |
        UInt32(mp4UInt8(at: i + 3))
    }

    func mp4UInt64BE(at i: Int) -> UInt64 {
        UInt64(mp4UInt32BE(at: i)) << 32 | UInt64(mp4UInt32BE(at: i + 4))
    }

    func mp4Int32BE(at i: Int) -> Int32 {
        Int32(bitPattern: mp4UInt32BE(at: i))
    }

    /// Read a 4-byte FourCC as a String (ISO Latin-1).
    func mp4FourCC(at i: Int) -> String {
        let bytes = [mp4UInt8(at: i), mp4UInt8(at: i + 1),
                     mp4UInt8(at: i + 2), mp4UInt8(at: i + 3)]
        return String(bytes: bytes, encoding: .isoLatin1) ?? "????"
    }
}
