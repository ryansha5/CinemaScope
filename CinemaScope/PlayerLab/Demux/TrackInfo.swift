// MARK: - PlayerLab / Demux / TrackInfo
//
// Metadata snapshot for a single track discovered during container parsing.
// Populated by MP4Demuxer after parse() completes.
// Read-only value type — safe to pass between contexts.

import Foundation
import CoreMedia

struct TrackInfo {

    // MARK: - Track type

    enum TrackType: CustomStringConvertible, Equatable {
        case video
        case audio
        case other(String)      // raw handler FourCC e.g. "subt", "meta"

        var description: String {
            switch self {
            case .video:          return "video"
            case .audio:          return "audio"
            case .other(let h):   return "other(\(h))"
            }
        }
    }

    // MARK: - Common fields

    let trackID:        UInt32
    let trackType:      TrackType
    let timescale:      UInt32          // ticks per second (from mdhd)
    let durationTicks:  UInt64          // duration in timescale units
    let sampleCount:    Int             // total samples in this track

    // MARK: - Video-specific (nil for audio tracks)

    /// FourCC of the sample entry, e.g. "avc1", "hev1", "av01".
    let codecFourCC:    String?

    /// Display dimensions from the track header (tkhd), integer pixels.
    let displayWidth:   UInt16?
    let displayHeight:  UInt16?

    /// Raw payload of the avcC box embedded inside the avc1 sample entry.
    /// Contains the SPS and PPS NAL units needed to configure VideoToolbox.
    /// nil for non-H.264 tracks.
    let avcCData:       Data?

    /// Raw payload of the hvcC box embedded inside the hvc1/hev1 sample entry.
    /// Contains VPS, SPS, and PPS NAL units for HEVC.
    /// nil for non-HEVC tracks.
    let hvcCData:       Data?

    // MARK: - Audio-specific (nil for video tracks)  — Sprint 13

    /// Raw payload of the esds box inside the mp4a sample entry.
    /// Contains the ES_Descriptor, whose DecoderSpecificInfo payload is the
    /// AudioSpecificConfig (the "magic cookie" for CMAudioFormatDescriptionCreate).
    let esdsData:        Data?

    /// Channel count from the mp4a AudioSampleEntry.
    let channelCount:    UInt16?

    /// Sample rate (Hz) from the mp4a AudioSampleEntry (fixed-point 16.16 → Double).
    let audioSampleRate: Double?

    // MARK: - Derived

    var durationSeconds: Double {
        guard timescale > 0 else { return 0 }
        return Double(durationTicks) / Double(timescale)
    }

    var isH264: Bool {
        codecFourCC == "avc1" || codecFourCC == "avc3"
    }

    /// Sprint 12: HEVC / H.265 codec families.
    var isHEVC: Bool {
        codecFourCC == "hvc1" || codecFourCC == "hev1"
    }

    /// Sprint 13: AAC audio.
    var isAAC: Bool { codecFourCC == "mp4a" }
}
