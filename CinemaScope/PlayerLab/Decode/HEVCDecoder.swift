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

// MARK: - Errors

enum HEVCDecoderError: Error, LocalizedError {
    case payloadTooShort(Int)
    case badConfigVersion(UInt8)
    case malformedNALArray(String)
    case noParameterSets
    case formatDescriptionFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .payloadTooShort(let n):        return "hvcC payload too short (\(n) bytes, need ≥ 23)"
        case .badConfigVersion(let v):       return "hvcC configurationVersion=\(v), expected 1"
        case .malformedNALArray(let reason): return "Malformed hvcC NAL array: \(reason)"
        case .noParameterSets:               return "hvcC contains no parameter-set NAL units"
        case .formatDescriptionFailed(let s):
            return "CMVideoFormatDescriptionCreateFromHEVCParameterSets failed: \(s)"
        }
    }
}

// MARK: - HEVCDecoder

final class HEVCDecoder {

    // MARK: - Format Description Factory (Sprint 12)

    /// Parse the raw hvcC box payload and return a CMVideoFormatDescription.
    ///
    /// - Parameter hvcCData: The raw bytes of the hvcC box (payload only,
    ///   header stripped).  Typically 40–100 bytes.
    /// - Returns: A CMVideoFormatDescription configured for HEVC decoding.
    static func makeFormatDescription(from hvcCData: Data) throws -> CMVideoFormatDescription {
        guard hvcCData.count >= 23 else {
            throw HEVCDecoderError.payloadTooShort(hvcCData.count)
        }
        guard hvcCData[0] == 1 else {
            throw HEVCDecoderError.badConfigVersion(hvcCData[0])
        }

        // byte [21]: ...| lengthSizeMinusOne (2 bits)
        let nalUnitLength = Int(hvcCData[21] & 0x03) + 1

        // byte [22]: numOfArrays
        let numArrays = Int(hvcCData[22])

        // Collect VPS / SPS / PPS NAL units.
        // CMVideoFormatDescriptionCreateFromHEVCParameterSets only needs those three
        // types.  ffmpeg libx265 often appends a 4th array (prefix-SEI, type 39);
        // including non-parameter-set NALUs in the API call can cause it to fail,
        // so we filter to the three known types and silently skip the rest.
        //
        // HEVC NAL unit types (lower 6 bits of the array-type byte):
        //   VPS = 32 (0x20)   SPS = 33 (0x21)   PPS = 34 (0x22)
        let kParameterSetTypes: Set<Int> = [32, 33, 34]

        var parameterSets: [Data] = []
        var idx = 23

        for arrayIdx in 0..<numArrays {
            // Each array header: 1 byte type + 2 bytes numNalus
            guard idx + 3 <= hvcCData.count else {
                throw HEVCDecoderError.malformedNALArray(
                    "array \(arrayIdx) header truncated at offset \(idx)"
                )
            }
            // byte 0: array_completeness(1) | reserved(1) | NAL_unit_type(6)
            // bytes 1-2: numNalus
            let nalType  = Int(hvcCData[idx] & 0x3F)   // lower 6 bits = HEVC NAL type
            let numNalus = Int(hvcCData[idx + 1]) << 8 | Int(hvcCData[idx + 2])
            idx += 3

            let keep = kParameterSetTypes.contains(nalType)

            for naluIdx in 0..<numNalus {
                guard idx + 2 <= hvcCData.count else {
                    throw HEVCDecoderError.malformedNALArray(
                        "array \(arrayIdx) NALU \(naluIdx) length field truncated at \(idx)"
                    )
                }
                let naluLen = Int(hvcCData[idx]) << 8 | Int(hvcCData[idx + 1])
                idx += 2
                guard idx + naluLen <= hvcCData.count else {
                    throw HEVCDecoderError.malformedNALArray(
                        "array \(arrayIdx) (type \(nalType)) NALU \(naluIdx) data truncated at \(idx); " +
                        "hvcC payload is \(hvcCData.count) bytes"
                    )
                }
                if keep {
                    parameterSets.append(hvcCData.subdata(in: idx..<(idx + naluLen)))
                }
                idx += naluLen
            }
        }

        guard !parameterSets.isEmpty else { throw HEVCDecoderError.noParameterSets }

        // Build CMVideoFormatDescription from all collected NAL units.
        // NSData pins the bytes in memory for the duration of the API call.
        let nsData = parameterSets.map { $0 as NSData }
        var ptrs   = nsData.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        var sizes  = nsData.map { $0.length }

        var fmtDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator:            kCFAllocatorDefault,
            parameterSetCount:    parameterSets.count,
            parameterSetPointers: &ptrs,
            parameterSetSizes:    &sizes,
            nalUnitHeaderLength:  Int32(nalUnitLength),
            extensions:           nil,
            formatDescriptionOut: &fmtDesc
        )

        guard status == noErr, let fmtDesc = fmtDesc else {
            throw HEVCDecoderError.formatDescriptionFailed(status)
        }

        return fmtDesc
    }
}
