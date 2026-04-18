// MARK: - PlayerLab / Subtitle / PGSParser
// Sprint 28 — PGS segment parser and CGImage renderer.
//
// Parses raw PGS (Presentation Graphic Stream) block payloads
// (no outer PG magic / PTS header — those come from the MKV block).
//
// Segments: PDS (palette), ODS (object bitmap), PCS (composition), WDS (window), END.
// Decodes RLE bitmaps and converts YCbCr palette to RGBA CGImage.
//
// NOT production-ready. Debug / lab use only.

import Foundation
import CoreGraphics

struct PGSParser {

    // MARK: - Segment type constants

    static let segPDS: UInt8 = 0x14  // Palette Definition Segment
    static let segODS: UInt8 = 0x15  // Object Definition Segment
    static let segPCS: UInt8 = 0x16  // Presentation Composition Segment
    static let segWDS: UInt8 = 0x17  // Window Definition Segment
    static let segEND: UInt8 = 0x80  // End of Display Set

    // MARK: - DisplaySet (mutable, built during parse)

    struct DisplaySet {
        var videoWidth:  Int = 0
        var videoHeight: Int = 0
        var isEpochStart: Bool = false
        var compositionObjects: [(objectID: Int, x: Int, y: Int)] = []
        var palette: [Int: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)] = [:]
        var objects: [Int: (width: Int, height: Int, pixels: [UInt8])] = [:]

        var hasBitmap: Bool {
            !compositionObjects.isEmpty && !objects.isEmpty
        }
    }

    // MARK: - Parse a raw block payload into a DisplaySet

    static func parseDisplaySet(data: Data) -> DisplaySet {
        var ds = DisplaySet()
        var fragments: [Int: (width: Int, height: Int, data: Data)] = [:]

        let bytes = [UInt8](data)
        var offset = 0

        while offset < bytes.count {
            guard offset + 3 <= bytes.count else { break }

            let segmentType = bytes[offset]
            offset += 1

            let segmentSize = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2

            guard offset + segmentSize <= bytes.count else { break }

            let segmentData = data.subdata(in: offset..<(offset + segmentSize))
            var segOffset = 0

            switch segmentType {
            case segPDS:
                parsePDS(data: segmentData, offset: &segOffset, size: segmentSize, into: &ds)
            case segODS:
                parseODS(data: segmentData, offset: &segOffset, size: segmentSize, into: &ds, fragments: &fragments)
            case segPCS:
                parsePCS(data: segmentData, offset: &segOffset, into: &ds)
            case segWDS:
                // Window Definition Segment — describes display window bounds.
                // Sprint 28: basic scope; data noted but not used for rendering.
                break
            case segEND:
                // End of Display Set
                break
            default:
                break
            }

            offset += segmentSize
        }

        return ds
    }

    // MARK: - Render DisplaySet → CGImage + objectRect

    static func makeImage(from displaySet: DisplaySet) -> (image: CGImage, rect: CGRect)? {
        guard let comp = displaySet.compositionObjects.first else { return nil }
        guard let obj  = displaySet.objects[comp.objectID]   else { return nil }
        let width = obj.width, height = obj.height
        guard width > 0, height > 0 else { return nil }

        // Map palette indices → RGBA bytes.
        // Transparent-black is the fallback for any unmapped index.
        let palette = displaySet.palette
        var rgba = [UInt8]()
        rgba.reserveCapacity(width * height * 4)
        for palIdx in obj.pixels {
            if let c = palette[Int(palIdx)] {
                rgba.append(c.r); rgba.append(c.g); rgba.append(c.b); rgba.append(c.a)
            } else {
                rgba.append(0); rgba.append(0); rgba.append(0); rgba.append(0)
            }
        }

        guard let cgImage = rgbaBufferToCGImage(rgba, width: width, height: height) else { return nil }
        let rect = CGRect(x: CGFloat(comp.x), y: CGFloat(comp.y),
                          width: CGFloat(width), height: CGFloat(height))
        return (cgImage, rect)
    }

    // MARK: - Private Helpers

    private static func parsePCS(data: Data, offset: inout Int, into ds: inout DisplaySet) {
        // PCS layout:
        //   [0..1]  video_width   — big-endian UInt16
        //   [2..3]  video_height  — big-endian UInt16
        //   [4]     frame_rate    — skip
        //   [5..6]  comp_number   — skip
        //   [7]     (skip)
        //   [8]     comp_state    — 0x80 = epoch start
        //   [9]     palette_update_flag — skip
        //   [10]    num_objects
        //   [11+]   composition objects (8 bytes each, +8 if cropped)
        guard data.count >= 11 else { return }

        let bytes = [UInt8](data)
        ds.videoWidth   = Int(UInt32(bytes[0]) << 8 | UInt32(bytes[1]))
        ds.videoHeight  = Int(UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        ds.isEpochStart = (bytes[8] & 0x80) != 0
        let numObjects  = Int(bytes[10])

        var objOffset = 11
        for _ in 0..<numObjects {
            guard objOffset + 8 <= bytes.count else { break }
            let objectID = Int(UInt32(bytes[objOffset])     << 8 | UInt32(bytes[objOffset + 1]))
            // bytes[objOffset + 2] = window_id (skip)
            let cropFlag = bytes[objOffset + 3]
            let x        = Int(UInt32(bytes[objOffset + 4]) << 8 | UInt32(bytes[objOffset + 5]))
            let y        = Int(UInt32(bytes[objOffset + 6]) << 8 | UInt32(bytes[objOffset + 7]))
            objOffset += 8
            if (cropFlag & 0x80) != 0 { objOffset += 8 }  // skip crop rectangle
            ds.compositionObjects.append((objectID: objectID, x: x, y: y))
        }
    }

    private static func parsePDS(data: Data, offset: inout Int, size: Int, into ds: inout DisplaySet) {
        // PDS layout:
        //   [0]  palette_id      — skip (we merge all entries into one dict)
        //   [1]  palette_version — skip
        //   [2+] entries of 5 bytes: entry_id, Y, Cr, Cb, T (transparency)
        //        Y/Cr/Cb are BT.601 limited range; T: 0 = transparent, 255 = opaque.
        guard size >= 2 else { return }
        let bytes = [UInt8](data)
        var idx = 2
        while idx + 5 <= bytes.count {
            let entryID = Int(bytes[idx])
            let y       = Int(bytes[idx + 1])
            let cr      = Int(bytes[idx + 2])
            let cb      = Int(bytes[idx + 3])
            let alpha   = bytes[idx + 4]

            // BT.601 limited range YCbCr → full-range RGB
            let y298 = (y - 16) * 298 + 128
            let r = clamp8((y298 + 409 * (cr - 128))                           >> 8)
            let g = clamp8((y298 - 100 * (cb - 128) - 208 * (cr - 128))        >> 8)
            let b = clamp8((y298 + 516 * (cb - 128))                           >> 8)

            ds.palette[entryID] = (r: r, g: g, b: b, a: alpha)
            idx += 5
        }
    }

    private static func parseODS(data: Data, offset: inout Int, size: Int,
                                 into ds: inout DisplaySet,
                                 fragments: inout [Int: (width: Int, height: Int, data: Data)]) {
        guard size >= 4 else { return }

        let bytes = [UInt8](data)

        let objectID = Int(UInt32(bytes[0]) << 8 | UInt32(bytes[1]))
        // bytes[2] = object version (skip)
        let lastInSeqFlag = bytes[3]

        let isFirstFragment = (lastInSeqFlag & 0x80) != 0
        let isLastFragment  = (lastInSeqFlag & 0x40) != 0

        if isFirstFragment {
            // First (or only) fragment: header contains object_data_length (3 bytes),
            // then width (2 bytes) and height (2 bytes).
            guard size >= 11 else { return }
            // bytes[4..6]: object_data_length — read but not strictly needed; skip.
            let width  = Int(UInt32(bytes[7]) << 8 | UInt32(bytes[8]))
            let height = Int(UInt32(bytes[9]) << 8 | UInt32(bytes[10]))
            guard width > 0, height > 0 else { return }

            let rleData = data.subdata(in: (data.startIndex + 11) ..< data.endIndex)
            if isLastFragment {
                // Complete single-segment object (0xC0 flag)
                if let pixels = decodeRLE(data: rleData, width: width, height: height) {
                    ds.objects[objectID] = (width: width, height: height, pixels: pixels)
                }
            } else {
                // Start of multi-segment object — store header info + first RLE chunk
                fragments[objectID] = (width: width, height: height, data: rleData)
            }
        } else if isLastFragment {
            // Final fragment of a multi-segment object (0x40 flag, no width/height)
            guard var existing = fragments[objectID] else { return }
            let rleData = data.subdata(in: (data.startIndex + 4) ..< data.endIndex)
            existing.data += rleData
            if let pixels = decodeRLE(data: existing.data,
                                       width: existing.width, height: existing.height) {
                ds.objects[objectID] = (width: existing.width,
                                         height: existing.height, pixels: pixels)
            }
            fragments.removeValue(forKey: objectID)
        } else {
            // Middle fragment — accumulate RLE bytes
            guard var existing = fragments[objectID] else { return }
            let rleData = data.subdata(in: (data.startIndex + 4) ..< data.endIndex)
            existing.data += rleData
            fragments[objectID] = existing
        }
    }

    private static func decodeRLE(data: Data, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        var result = [UInt8]()
        result.reserveCapacity(width * height)

        let bytes = [UInt8](data)
        var byteIdx = 0
        var x = 0
        var y = 0

        while y < height && byteIdx < bytes.count {
            let byte = bytes[byteIdx]
            byteIdx += 1

            if byte != 0 {
                // Single pixel at palette index
                result.append(byte)
                x += 1
                if x >= width {
                    x = 0
                    y += 1
                }
            } else {
                // Run code
                guard byteIdx < bytes.count else { break }
                let next = bytes[byteIdx]
                byteIdx += 1

                if next == 0 {
                    // End of line
                    x = 0
                    y += 1
                } else if (next & 0xC0) == 0x00 {
                    // Run of 0 pixels (transparent): (next & 0x3F) pixels
                    let count = Int(next & 0x3F)
                    for _ in 0..<count {
                        result.append(0)
                        x += 1
                        if x >= width {
                            x = 0
                            y += 1
                        }
                    }
                } else if (next & 0xC0) == 0x40 {
                    // Long run of 0 pixels: count = ((next & 0x3F) << 8) | nextByte
                    guard byteIdx < bytes.count else { break }
                    let lo = bytes[byteIdx]
                    byteIdx += 1
                    let count = (Int(next & 0x3F) << 8) | Int(lo)
                    for _ in 0..<count {
                        result.append(0)
                        x += 1
                        if x >= width {
                            x = 0
                            y += 1
                        }
                    }
                } else if (next & 0xC0) == 0x80 {
                    // Run of color pixels: (next & 0x3F) pixels at given color
                    guard byteIdx < bytes.count else { break }
                    let color = bytes[byteIdx]
                    byteIdx += 1
                    let count = Int(next & 0x3F)
                    for _ in 0..<count {
                        result.append(color)
                        x += 1
                        if x >= width {
                            x = 0
                            y += 1
                        }
                    }
                } else { // (next & 0xC0) == 0xC0
                    // Long run of color pixels: count = ((next & 0x3F) << 8) | nextByte
                    guard byteIdx + 1 < bytes.count else { break }
                    let lo = bytes[byteIdx]
                    let color = bytes[byteIdx + 1]
                    byteIdx += 2
                    let count = (Int(next & 0x3F) << 8) | Int(lo)
                    for _ in 0..<count {
                        result.append(color)
                        x += 1
                        if x >= width {
                            x = 0
                            y += 1
                        }
                    }
                }
            }
        }

        return result.count == width * height ? result : nil
    }

    private static func clamp8(_ v: Int) -> UInt8 {
        if v < 0 { return 0 }
        if v > 255 { return 255 }
        return UInt8(v)
    }

    // MARK: - RGBA buffer → CGImage

    private static func rgbaBufferToCGImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard !rgba.isEmpty, rgba.count == width * height * 4 else { return nil }

        let data = NSMutableData(bytes: rgba, length: rgba.count)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )

        return cgImage
    }
}
