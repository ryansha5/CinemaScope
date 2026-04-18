// MARK: - PlayerLab / Audio / TrueHDCoreExtractor
// Sprint 34 — TrueHD → AC3 Core Extraction.
//
// Blu-ray HDMV TrueHD streams (A_TRUEHD in MKV) routinely carry an embedded
// AC3 "core" track for backward compatibility.  The AC3 frames are interleaved
// with TrueHD frames inside the same packet stream; each AC3 frame begins with
// the standard sync word 0x0B77.
//
// This file provides:
//   • AC3 frame size lookup table (ATSC A/52, 38 frmsizecod × 3 sample-rates)
//   • hasAC3Core(in:)           — fast O(n) scan for 0x0B77 sync word
//   • extractFirstAC3Frame(from:) — returns first complete AC3 frame as Data
//   • probeAC3(in:)             — parses frame header fields (sr, size, channels)
//
// Usage:
//   1. Probe a packet: `TrueHDCoreExtractor.probeAC3(in: packet.data)`
//   2. Per-frame extraction: `TrueHDCoreExtractor.extractFirstAC3Frame(from: data)`
//
// NOT production-ready. Debug / lab use only.

import Foundation

// MARK: - AC3FrameInfo

/// Metadata parsed from an AC3 frame header found inside a TrueHD packet.
struct AC3FrameInfo {
    /// Decoded sample rate in Hz (48000, 44100, or 32000).
    let sampleRate:   Int
    /// Total frame size in bytes (including sync word and headers).
    let frameBytes:   Int
    /// Channel count from `acmod` field.  Does *not* include LFE (subwoofer)
    /// because parsing the LFE bit requires variable-width header traversal.
    /// Caller should use the MKV track-header channel count when accurate count matters.
    let channelCount: Int
}

// MARK: - TrueHDCoreExtractor

enum TrueHDCoreExtractor {

    // MARK: - AC3 Sync Word

    private static let syncByte0: UInt8 = 0x0B
    private static let syncByte1: UInt8 = 0x77

    // Minimum valid AC3 frame: sync(2) + crc1(2) + fscod/frmsizecod(1) = 5 bytes
    private static let minAC3HeaderBytes = 7   // need up to byte 6 for acmod

    // MARK: - Frame Size Table (ATSC A/52 Table 4.13)
    //
    // Index = frmsizecod (0–37).  Three columns: 48 kHz, 44.1 kHz, 32 kHz.
    // Values are frame sizes in 16-bit *words*; multiply by 2 for bytes.

    private static let frameSizeWords: [[Int]] = [
        /* 00 */ [64,   69,   96  ],
        /* 01 */ [64,   70,   96  ],
        /* 02 */ [80,   87,   120 ],
        /* 03 */ [80,   88,   120 ],
        /* 04 */ [96,   104,  144 ],
        /* 05 */ [96,   105,  144 ],
        /* 06 */ [112,  121,  168 ],
        /* 07 */ [112,  122,  168 ],
        /* 08 */ [128,  139,  192 ],
        /* 09 */ [128,  140,  192 ],
        /* 10 */ [160,  174,  240 ],
        /* 11 */ [160,  175,  240 ],
        /* 12 */ [192,  208,  288 ],
        /* 13 */ [192,  209,  288 ],
        /* 14 */ [224,  243,  336 ],
        /* 15 */ [224,  244,  336 ],
        /* 16 */ [256,  278,  384 ],
        /* 17 */ [256,  279,  384 ],
        /* 18 */ [320,  348,  480 ],
        /* 19 */ [320,  349,  480 ],
        /* 20 */ [384,  417,  576 ],
        /* 21 */ [384,  418,  576 ],
        /* 22 */ [448,  487,  672 ],
        /* 23 */ [448,  488,  672 ],
        /* 24 */ [512,  557,  768 ],
        /* 25 */ [512,  558,  768 ],
        /* 26 */ [640,  696,  960 ],
        /* 27 */ [640,  697,  960 ],
        /* 28 */ [768,  835,  1152],
        /* 29 */ [768,  836,  1152],
        /* 30 */ [896,  975,  1344],
        /* 31 */ [896,  976,  1344],
        /* 32 */ [1024, 1114, 1536],
        /* 33 */ [1024, 1115, 1536],
        /* 34 */ [1152, 1253, 1728],
        /* 35 */ [1152, 1254, 1728],
        /* 36 */ [1280, 1393, 1920],
        /* 37 */ [1280, 1394, 1920],
    ]

    // Sample rates indexed by fscod (0 = 48 kHz, 1 = 44.1 kHz, 2 = 32 kHz).
    private static let sampleRates: [Int] = [48_000, 44_100, 32_000]

    // Channel counts by acmod (3-bit field; does not include LFE channel).
    private static let acmodChannels: [Int] = [2, 1, 2, 3, 3, 4, 4, 5]

    // MARK: - Public API

    /// Returns `true` if `data` contains at least one AC3 sync word (0x0B77).
    ///
    /// Stops at the first match for maximum speed.  Does *not* validate the full
    /// frame header, so a false positive is possible if audio data happens to
    /// contain 0x0B77.  Use `probeAC3(in:)` for validated detection.
    static func hasAC3Core(in data: Data) -> Bool {
        let count = data.count
        guard count >= 2 else { return false }
        let base = data.startIndex
        for i in 0..<(count - 1) {
            if data[base + i] == syncByte0,
               data[base + i + 1] == syncByte1 {
                return true
            }
        }
        return false
    }

    /// Scans `data` for the first valid AC3 sync frame and returns its raw bytes.
    ///
    /// Searches for 0x0B77, validates fscod/frmsizecod, and returns a subdata
    /// slice of exactly `frameBytes` bytes.  Returns `nil` if no valid AC3 frame
    /// is found or if the data is truncated before the frame ends.
    static func extractFirstAC3Frame(from data: Data) -> Data? {
        guard let info = firstValidAC3(in: data) else { return nil }
        return info.data
    }

    /// Parses the first valid AC3 frame header in `data` and returns metadata.
    ///
    /// Returns `nil` when no valid AC3 sync frame is found.
    static func probeAC3(in data: Data) -> AC3FrameInfo? {
        return firstValidAC3(in: data)?.info
    }

    // MARK: - Private helpers

    private struct ParseResult {
        let info: AC3FrameInfo
        let data: Data
    }

    /// Scans forward for 0x0B77, validates the frame header, and returns both
    /// the parsed metadata and the raw frame bytes.
    private static func firstValidAC3(in data: Data) -> ParseResult? {
        let count = data.count
        guard count >= minAC3HeaderBytes else { return nil }
        let base = data.startIndex

        var i = 0
        while i < count - minAC3HeaderBytes {
            // Look for sync word
            guard data[base + i] == syncByte0,
                  data[base + i + 1] == syncByte1
            else {
                i += 1
                continue
            }

            // Byte 4 (relative to sync start): fscod[7:6] | frmsizecod[5:0]
            let byte4 = Int(data[base + i + 4])
            let fscod      = (byte4 >> 6) & 0x03
            let frmsizecod = byte4 & 0x3F

            // Validate fscod (3 = reserved / invalid)
            guard fscod < 3 else { i += 1; continue }
            // Validate frmsizecod
            guard frmsizecod < frameSizeWords.count else { i += 1; continue }

            let frameSizeW = frameSizeWords[frmsizecod][fscod]
            let frameBytes = frameSizeW * 2

            // Validate bsid: byte 5 bits[7:3] — must be ≤ 8 for standard AC3
            let bsid = (Int(data[base + i + 5]) >> 3) & 0x1F
            guard bsid <= 8 else { i += 1; continue }

            // Ensure the full frame fits in the data
            guard i + frameBytes <= count else { i += 1; continue }

            // Channel count: acmod is bits [7:5] of byte 6
            let acmod = (Int(data[base + i + 6]) >> 5) & 0x07
            let ch    = acmodChannels[acmod]

            let sr   = sampleRates[fscod]
            let info = AC3FrameInfo(sampleRate: sr, frameBytes: frameBytes, channelCount: ch)
            let raw  = data.subdata(in: (base + i)..<(base + i + frameBytes))
            return ParseResult(info: info, data: raw)
        }
        return nil
    }
}
