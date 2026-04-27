// MARK: - PlayerLab / Decode / HEVCDecoder
//
// Sprint 12 — HEVC Path
//
// Parses a raw hvcC box payload and creates a CMVideoFormatDescription
// suitable for use with AVSampleBufferDisplayLayer.
//
// hvcC contains arrays of NAL units (VPS, SPS, PPS, SEI, …).
// CMVideoFormatDescriptionCreateFromHEVCParameterSets needs all of them.
//
// Box layout (ISO 14496-15 §8.3.3.1):
//   [0]    configurationVersion          must be 1
//   [1]    general_profile_space(2) | general_tier_flag(1) | general_profile_idc(5)
//   [2-5]  general_profile_compatibility_flags
//   [6-11] general_constraint_indicator_flags (6 bytes)
//   [12]   general_level_idc
//   [13-14] 4-bit reserved(0b1111) | min_spatial_segmentation_idc(12)
//   [15]   6-bit reserved | parallelismType(2)
//   [16]   6-bit reserved | chroma_format_idc(2)
//   [17]   5-bit reserved | bit_depth_luma_minus8(3)
//   [18]   5-bit reserved | bit_depth_chroma_minus8(3)
//   [19-20] avgFrameRate
//   [21]   constantFrameRate(2) | numTemporalLayers(3) | temporalIdNested(1) | lengthSizeMinusOne(2)
//   [22]   numOfArrays
//   [23+]  NAL unit arrays (one per array):
//            [0]   array_completeness(1) | reserved(1) | nal_unit_type(6)
//            [1-2] numNalus  (big-endian uint16)
//            For each NAL:
//              [0-1] naluLength  (big-endian uint16)
//              [...]  NALU bytes
//
// NOT production. Debug / lab use only.

import Foundation
import VideoToolbox
import CoreMedia

// MARK: - Stderr logging (unbuffered — survives hard crash / SIGABRT)
//
// FileHandle.standardError bypasses Swift's stdout buffer: writes reach the
// Xcode console even if the process aborts before stdout can flush.

private func errLog(_ msg: String) {
    guard let data = (msg + "\n").data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}

// MARK: - Errors

enum HEVCDecoderError: Error, LocalizedError {
    case payloadTooShort(Int)
    case badConfigVersion(UInt8)
    case malformedNALArray(String)
    case noParameterSets
    case missingParameterSetType(String)
    case formatDescriptionFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .payloadTooShort(let n):
            return "hvcC payload too short (\(n) bytes, need ≥ 23)"
        case .badConfigVersion(let v):
            return "hvcC configurationVersion=\(v), expected 1"
        case .malformedNALArray(let reason):
            return "Malformed hvcC NAL array: \(reason)"
        case .noParameterSets:
            return "hvcC contains no parameter-set NAL units (VPS/SPS/PPS)"
        case .missingParameterSetType(let m):
            return "Missing HEVC parameter set: \(m)"
        case .formatDescriptionFailed(let s):
            return "CMVideoFormatDescriptionCreateFromHEVCParameterSets failed: OSStatus=\(s)"
        }
    }
}

// MARK: - HEVCDecoder

final class HEVCDecoder {

    // MARK: - Sanity limits (prevent runaway loops on corrupt data)
    private static let maxArrays:    Int = 16
    private static let maxNALsPerArray: Int = 64
    private static let maxNALSize:   Int = 65536   // 64 KB — no real param set is larger

    // MARK: - Format Description Factory

    /// Parse a raw hvcC box payload and return a CMVideoFormatDescription.
    ///
    /// All diagnostic output goes to **stderr** (unbuffered) so messages appear
    /// in the Xcode console even if VideoToolbox crashes the process before
    /// stdout can flush.
    ///
    /// - Important: `hvcCData` is flattened to `[UInt8]` on entry to guarantee
    ///   0-based indexing.  Swift `Data` slices retain the indices of their
    ///   parent buffer, so direct subscript `data[0]` on a slice triggers an
    ///   out-of-bounds trap when the slice does not start at offset 0.
    ///
    /// - Parameters:
    ///   - hvcCData: Raw bytes of the hvcC box (payload only, box header stripped).
    ///   - label:    Context tag for log lines (e.g. "Prepare #1").
    static func makeFormatDescription(from hvcCData: Data,
                                      label: String = "") throws -> CMVideoFormatDescription {

        let tag = label.isEmpty ? "[HEVCDecoder]" : "[HEVCDecoder \(label)]"

        // ── CRITICAL: flatten to [UInt8] ─────────────────────────────────────
        // Data created via slice subscript (data[lo..<hi]) retains the parent's
        // indices.  Accessing such a slice with hvcCData[0] crashes when the
        // slice's startIndex != 0.  Array(hvcCData) always produces 0-based
        // indices regardless of how the original Data was constructed.
        let b = Array(hvcCData)
        let n = b.count

        errLog("\(tag) ── hvcC parse start ─────────────────────────────────")
        errLog("\(tag) payload=\(n)B  "
             + "first4=\(b.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " "))")

        // ── Minimum length ────────────────────────────────────────────────────
        guard n >= 23 else {
            errLog("\(tag) ❌ payload too short (\(n)B, need ≥23)")
            throw HEVCDecoderError.payloadTooShort(n)
        }
        errLog("\(tag) length check ✅ (\(n)B ≥ 23)")

        // ── configurationVersion ──────────────────────────────────────────────
        let configVersion = b[0]
        errLog("\(tag) configurationVersion=\(configVersion) \(configVersion == 1 ? "✅" : "❌ expected 1")")
        guard configVersion == 1 else {
            throw HEVCDecoderError.badConfigVersion(configVersion)
        }

        // ── Profile / tier / level ────────────────────────────────────────────
        let profileSpace = (b[1] >> 6) & 0x03
        let tierFlag     = (b[1] >> 5) & 0x01
        let profileIdc   =  b[1]       & 0x1F
        let levelIdc     = b[12]
        errLog("\(tag) profile_space=\(profileSpace)  tier_flag=\(tierFlag)  "
             + "profile_idc=\(profileIdc)  level_idc=\(levelIdc)")

        // ── lengthSizeMinusOne / numOfArrays ─────────────────────────────────
        let lengthSizeMinusOne = b[21] & 0x03
        let nalUnitLength      = Int(lengthSizeMinusOne) + 1
        let numArrays          = Int(b[22])
        errLog("\(tag) lengthSizeMinusOne=\(lengthSizeMinusOne)  "
             + "nalUnitLength=\(nalUnitLength)  numOfArrays=\(numArrays)  "
             + "parse offset after header=23")

        guard numArrays > 0 else {
            errLog("\(tag) ❌ numOfArrays=0 — no parameter sets")
            throw HEVCDecoderError.noParameterSets
        }
        guard numArrays <= HEVCDecoder.maxArrays else {
            errLog("\(tag) ❌ numOfArrays=\(numArrays) exceeds sanity limit \(HEVCDecoder.maxArrays)")
            throw HEVCDecoderError.malformedNALArray("numOfArrays=\(numArrays) exceeds limit \(HEVCDecoder.maxArrays)")
        }

        // ── NAL array parsing ─────────────────────────────────────────────────
        // Collect VPS(32) / SPS(33) / PPS(34) tagged with their HEVC NAL type.
        let kParameterSetTypes: Set<Int> = [32, 33, 34]
        typealias TaggedNAL = (nalType: Int, data: Data)
        var collected: [TaggedNAL] = []
        var cursor = 23      // current byte offset into b[]

        for arrayIdx in 0..<numArrays {

            let cursorBefore = cursor

            // ── Array header: 1-byte type + 2-byte numNalus ──────────────────
            guard cursor + 3 <= n else {
                errLog("\(tag) ❌ array[\(arrayIdx)] header truncated: "
                     + "cursor=\(cursor) need \(cursor + 3) have \(n)")
                throw HEVCDecoderError.malformedNALArray(
                    "array[\(arrayIdx)] header truncated at cursor=\(cursor), payload=\(n)B")
            }

            let arrayType = Int(b[cursor] & 0x3F)          // lower 6 bits
            let numNalus  = Int(b[cursor + 1]) << 8 | Int(b[cursor + 2])
            cursor += 3

            let typeName: String
            switch arrayType {
            case 32: typeName = "VPS"
            case 33: typeName = "SPS"
            case 34: typeName = "PPS"
            case 39: typeName = "prefix-SEI"
            case 40: typeName = "suffix-SEI"
            default: typeName = "type\(arrayType)"
            }
            let keep = kParameterSetTypes.contains(arrayType)
            errLog("\(tag) array[\(arrayIdx + 1)/\(numArrays)] "
                 + "type=\(arrayType) (\(typeName))  numNalus=\(numNalus)  "
                 + "\(keep ? "→ KEEP" : "→ skip")")

            guard numNalus > 0 else {
                errLog("\(tag)   ⚠️ numNalus=0 — skipping empty array")
                continue
            }
            guard numNalus <= HEVCDecoder.maxNALsPerArray else {
                errLog("\(tag) ❌ numNalus=\(numNalus) exceeds sanity limit \(HEVCDecoder.maxNALsPerArray)")
                throw HEVCDecoderError.malformedNALArray(
                    "array[\(arrayIdx)] numNalus=\(numNalus) exceeds limit \(HEVCDecoder.maxNALsPerArray)")
            }

            // ── Individual NAL units ──────────────────────────────────────────
            for naluIdx in 0..<numNalus {

                // 2-byte length prefix
                guard cursor + 2 <= n else {
                    errLog("\(tag) ❌ array[\(arrayIdx)] nalu[\(naluIdx)] "
                         + "length field truncated: cursor=\(cursor) need \(cursor+2) have \(n)")
                    throw HEVCDecoderError.malformedNALArray(
                        "array[\(arrayIdx)] nalu[\(naluIdx)] length field truncated "
                        + "cursor=\(cursor) payload=\(n)B")
                }
                let naluLen = Int(b[cursor]) << 8 | Int(b[cursor + 1])
                cursor += 2

                errLog("\(tag)   nalu[\(naluIdx)] declared size=\(naluLen)B  cursor=\(cursor)")

                guard naluLen > 0 else {
                    errLog("\(tag)   ⚠️ zero-length NALU in \(typeName) — skipping")
                    // cursor already advanced past the 2-byte length; no payload bytes to skip
                    continue
                }
                guard naluLen <= HEVCDecoder.maxNALSize else {
                    errLog("\(tag) ❌ nalu[\(naluIdx)] size=\(naluLen) exceeds sanity limit \(HEVCDecoder.maxNALSize)")
                    throw HEVCDecoderError.malformedNALArray(
                        "\(typeName) nalu[\(naluIdx)] size=\(naluLen) exceeds limit")
                }
                guard cursor + naluLen <= n else {
                    errLog("\(tag) ❌ array[\(arrayIdx)] (\(typeName)) nalu[\(naluIdx)] "
                         + "payload truncated: cursor=\(cursor) need \(cursor + naluLen) have \(n)")
                    throw HEVCDecoderError.malformedNALArray(
                        "array[\(arrayIdx)] (\(typeName)) nalu[\(naluIdx)] "
                        + "payload truncated cursor=\(cursor) naluLen=\(naluLen) payload=\(n)B")
                }

                if keep {
                    let naluBytes = Data(b[cursor..<(cursor + naluLen)])
                    let first4 = naluBytes.prefix(4)
                        .map { String(format: "%02X", $0) }.joined(separator: " ")
                    errLog("\(tag)   → collected \(typeName) size=\(naluLen)B  first4=\(first4)")
                    collected.append((nalType: arrayType, data: naluBytes))
                }

                cursor += naluLen
            }

            // Cursor must have advanced; detect infinite-loop on corrupt data
            guard cursor > cursorBefore else {
                errLog("\(tag) ❌ cursor did not advance in array[\(arrayIdx)] — aborting")
                throw HEVCDecoderError.malformedNALArray(
                    "cursor stalled at \(cursor) in array[\(arrayIdx)]")
            }
        }

        errLog("\(tag) ── array parse complete ──  "
             + "cursor=\(cursor)/\(n)  collected=\(collected.count)")

        // ── Sort VPS→SPS→PPS and deduplicate ──────────────────────────────────
        // CMVideoFormatDescriptionCreateFromHEVCParameterSets internally asserts
        // the order is VPS(32) → SPS(33) → PPS(34).  Passing out-of-order or
        // duplicate sets causes an EXC_BREAKPOINT trap inside VideoToolbox.
        let sorted = collected.sorted { $0.nalType < $1.nalType }
        var seenTypes = Set<Int>()
        let parameterSets: [Data] = sorted.compactMap { tagged in
            guard seenTypes.insert(tagged.nalType).inserted else {
                errLog("\(tag) ⚠️ duplicate type=\(tagged.nalType) — dropped")
                return nil
            }
            return tagged.data
        }
        errLog("\(tag) parameterSets after dedup: \(parameterSets.count)")

        // ── Validate required types ───────────────────────────────────────────
        let presentTypes = Set(parameterSets.indices.map { sorted[$0].nalType })
        errLog("\(tag) VPS present: \(presentTypes.contains(32) ? "✅" : "❌ MISSING")")
        errLog("\(tag) SPS present: \(presentTypes.contains(33) ? "✅" : "❌ MISSING")")
        errLog("\(tag) PPS present: \(presentTypes.contains(34) ? "✅" : "❌ MISSING")")

        if !presentTypes.contains(32) { throw HEVCDecoderError.missingParameterSetType("VPS (type 32)") }
        if !presentTypes.contains(33) { throw HEVCDecoderError.missingParameterSetType("SPS (type 33)") }
        if !presentTypes.contains(34) { throw HEVCDecoderError.missingParameterSetType("PPS (type 34)") }

        // ── Final summary before CoreMedia call ───────────────────────────────
        let sizes: [Int] = parameterSets.map { $0.count }
        errLog("\(tag) ── ready to call CoreMedia ─────────────────────────────")
        errLog("\(tag) parameterSetCount=\(parameterSets.count)  "
             + "nalUnitHeaderLength=\(nalUnitLength)  "
             + "sizes=\(sizes)")
        for (i, ps) in parameterSets.enumerated() {
            let nt: UInt8 = ps.count >= 2 ? (ps[0] >> 1) & 0x3F : 0xFF
            let name = nt == 32 ? "VPS" : nt == 33 ? "SPS" : nt == 34 ? "PPS" : "?\(nt)"
            errLog("\(tag)   [\(i)] \(name) size=\(ps.count)B  "
                 + "first4=\(ps.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " "))")
        }

        // ── Build CMVideoFormatDescription ────────────────────────────────────
        //
        // Use value-passing recursive nesting of withUnsafeBytes closures so
        // ALL Data regions are simultaneously pinned when the CoreMedia call
        // executes at the base case.
        //
        // WHY NOT inout: Swift exclusivity rules prohibit capturing an inout
        // parameter across a closure boundary.  Passing ptrs by value at each
        // recursion level (via array concatenation) avoids the violation while
        // keeping all pinned regions live.
        func pinAndCall(idx: Int, ptrs: [UnsafePointer<UInt8>]) throws -> CMVideoFormatDescription {
            if idx < parameterSets.count {
                return try parameterSets[idx].withUnsafeBytes { rawBuf in
                    // withUnsafeBytes guarantees non-nil baseAddress.
                    let ptr = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    return try pinAndCall(idx: idx + 1, ptrs: ptrs + [ptr])
                }
            } else {
                var mutablePtrs  = ptrs
                var mutableSizes = sizes
                errLog("\(tag) ▶ CMVideoFormatDescriptionCreateFromHEVCParameterSets  "
                     + "count=\(parameterSets.count)  nalUnitHeaderLength=\(nalUnitLength)")
                var fmtDesc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator:            kCFAllocatorDefault,
                    parameterSetCount:    parameterSets.count,
                    parameterSetPointers: &mutablePtrs,
                    parameterSetSizes:    &mutableSizes,
                    nalUnitHeaderLength:  Int32(nalUnitLength),
                    extensions:           nil,
                    formatDescriptionOut: &fmtDesc
                )
                errLog("\(tag) ◀ status=\(status)  "
                     + "fmtDesc=\(fmtDesc != nil ? "✅ non-nil" : "❌ nil")")
                guard status == noErr, let fmtDesc else {
                    throw HEVCDecoderError.formatDescriptionFailed(status)
                }
                return fmtDesc
            }
        }

        errLog("\(tag) ── entering pinAndCall ──────────────────────────────────")
        return try pinAndCall(idx: 0, ptrs: [])
    }
}
