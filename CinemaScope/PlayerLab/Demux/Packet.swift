// MARK: - PlayerLab / Demux / Packet
//
// Normalized, container-agnostic demux packet.
//
// For H.264 from MP4, `data` contains AVCC-format samples:
//   each NAL unit is prefixed by a big-endian length field
//   (width determined by avcC's lengthSizeMinusOne, usually 4 bytes).
//   VideoToolbox accepts this format directly when the CMFormatDescription
//   was created via CMVideoFormatDescriptionCreateFromH264ParameterSets.
//
// Designed so MKV/EBML can reuse the same type later.

import Foundation
import CoreMedia

struct DemuxPacket {

    enum StreamType: CustomStringConvertible {
        case video
        case audio
        var description: String { self == .video ? "video" : "audio" }
    }

    /// Which elementary stream this packet belongs to.
    let streamType:  StreamType

    /// 0-based sample index within the track.
    let index:       Int

    /// Presentation timestamp (display order).
    let pts:         CMTime

    /// Decode timestamp (decode order, equals pts when no B-frames).
    let dts:         CMTime

    /// Compressed sample bytes.
    /// H.264/MP4: AVCC length-prefixed NAL units.
    let data:        Data

    /// True if this sample is a sync / random-access point (IDR for H.264).
    let isKeyframe:  Bool

    /// File byte offset of this sample's first byte.
    let byteOffset:  Int64

    /// Per-sample duration (used for audio CMSampleBuffers).
    /// .invalid for video (AVSBDL infers duration from consecutive PTS values).
    let duration:    CMTime
}
