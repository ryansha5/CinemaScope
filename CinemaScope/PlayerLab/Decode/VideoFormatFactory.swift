// MARK: - PlayerLab / Decode / VideoFormatFactory
// Spring Cleaning SC3A — Centralized video format-description construction.
// Extracted from PlayerLabPlaybackController.prepare() (Sprint 10 / Sprint 12).
//
// Mirrors AudioFormatFactory from SC1.
//
// Handles:
//   • H.264  (avcCData  → H264Decoder.makeFormatDescription)
//   • HEVC   (hvcCData  → HEVCDecoder.makeFormatDescription)
//
// Designed to accept future codec additions (AV1, VP9, …) without touching
// the controller.
//
// NOT production-ready. Debug / lab use only.

import Foundation
import CoreMedia

// MARK: - Errors

enum VideoFormatFactoryError: Error, LocalizedError {
    case missingParameterData(String)
    case unsupportedCodec(String)

    var errorDescription: String? {
        switch self {
        case .missingParameterData(let m): return m
        case .unsupportedCodec(let c):
            return "Unsupported video codec '\(c)' — fallback to AVPlayer"
        }
    }
}

// MARK: - VideoFormatFactory

enum VideoFormatFactory {

    // MARK: - Unified entry point

    /// Build a `CMVideoFormatDescription` for `videoTrack`.
    ///
    /// Dispatches internally:
    ///   • `isH264` + `avcCData` → H264Decoder.makeFormatDescription
    ///   • `isHEVC` + `hvcCData` → HEVCDecoder.makeFormatDescription
    ///
    /// Throws `VideoFormatFactoryError` on missing parameter data or unsupported codec.
    /// The `record` closure receives `[5]`-prefixed status messages matching the
    /// existing prepare() log style.
    ///
    /// - Parameters:
    ///   - videoTrack: The TrackInfo for the selected video track.
    ///   - record:     Logging callback forwarded from the controller.
    static func make(
        for videoTrack: TrackInfo,
        record:         (String) -> Void
    ) throws -> CMVideoFormatDescription {

        let fourCC = videoTrack.codecFourCC ?? "?"
        record("[5] Building CMVideoFormatDescription (\(fourCC))…")

        if videoTrack.isH264 {
            guard let avcC = videoTrack.avcCData else {
                throw VideoFormatFactoryError.missingParameterData(
                    "H.264 track has no avcC data")
            }
            let desc = try H264Decoder.makeFormatDescription(from: avcC)
            record("  ✅ H.264 format description (avcC \(avcC.count) bytes)")
            return desc
        }

        if videoTrack.isHEVC {
            guard let hvcC = videoTrack.hvcCData else {
                throw VideoFormatFactoryError.missingParameterData(
                    "HEVC track has no hvcC data")
            }
            let desc = try HEVCDecoder.makeFormatDescription(from: hvcC)
            record("  ✅ HEVC format description (hvcC \(hvcC.count) bytes)")
            return desc
        }

        throw VideoFormatFactoryError.unsupportedCodec(fourCC)
    }
}
