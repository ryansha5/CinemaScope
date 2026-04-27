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
    ///
    /// - Parameters:
    ///   - videoTrack: The TrackInfo for the selected video track.
    ///   - label:      Context tag forwarded to codec decoders for log lines
    ///                 (e.g. "Prepare #3"). Empty string disables the tag.
    ///   - record:     Logging callback forwarded from the controller.
    static func make(
        for videoTrack: TrackInfo,
        label:          String = "",
        record:         (String) -> Void
    ) throws -> CMVideoFormatDescription {

        let fourCC   = videoTrack.codecFourCC ?? "?"
        let labelTag = label.isEmpty ? "" : " [\(label)]"

        // The controller already logs the full "[5] Building…" line with codec
        // detail before reaching here.  Log factory-internal progress under a
        // distinct prefix so the two lines are clearly distinguishable.
        record("[VideoFormatFactory\(labelTag)] enter  codec=\(fourCC)  "
             + "isH264=\(videoTrack.isH264)  isHEVC=\(videoTrack.isHEVC)  "
             + "hvcC=\(videoTrack.hvcCData.map { "\($0.count)B" } ?? "nil")  "
             + "avcC=\(videoTrack.avcCData.map { "\($0.count)B" } ?? "nil")")

        if videoTrack.isH264 {
            guard let avcC = videoTrack.avcCData else {
                throw VideoFormatFactoryError.missingParameterData(
                    "H.264 track has no avcC data")
            }
            let desc = try H264Decoder.makeFormatDescription(from: avcC)
            record("[VideoFormatFactory\(labelTag)] ✅ H.264 format description  avcC=\(avcC.count)B")
            return desc
        }

        if videoTrack.isHEVC {
            guard let hvcC = videoTrack.hvcCData else {
                throw VideoFormatFactoryError.missingParameterData(
                    "HEVC track has no hvcC data")
            }
            record("[VideoFormatFactory\(labelTag)] → HEVCDecoder.makeFormatDescription  "
                 + "hvcC=\(hvcC.count)B  (per-step trace on stderr)")
            let desc = try HEVCDecoder.makeFormatDescription(from: hvcC, label: label)
            record("[VideoFormatFactory\(labelTag)] ✅ HEVC format description  hvcC=\(hvcC.count)B")
            return desc
        }

        throw VideoFormatFactoryError.unsupportedCodec(fourCC)
    }
}
