// MARK: - PlayerLab / Subtitle / PGSCue
//
// Sprint 28 — PGS (Presentation Graphic Stream) bitmap subtitle cue.
//
// Bitmap subtitles from MKV S_HDMV/PGS tracks.
// Each cue carries a pre-decoded CGImage and the video-space position rect.
//
// Rendering: PGSSubtitleView scales objectRect from videoSize coordinates
// to the actual display size, preserving aspect ratio.
//
// NOT production-ready. Debug / lab use only.

import Foundation
import CoreMedia
import CoreGraphics

struct PGSCue: Identifiable {

    /// Stable identity for SwiftUI diffing.
    let id: UUID

    /// Presentation start time (inclusive).
    let startTime: CMTime

    /// Presentation end time (exclusive).
    let endTime: CMTime

    /// Pre-decoded subtitle bitmap.  nil indicates a "clear" cue with no image.
    let image: CGImage?

    /// The video resolution this cue was authored for (from PCS video_width/height).
    let videoSize: CGSize

    /// Position and size of the subtitle object in video-space coordinates.
    /// Origin is top-left of the video frame.
    let objectRect: CGRect

    var hasImage: Bool { image != nil }
}
