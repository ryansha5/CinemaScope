// MARK: - PlayerLab / Subtitle / PGSCue
//
// Sprint 28 — PGS (Presentation Graphic Stream) bitmap subtitle cue.
// Sprint 38 — isForced and windowRect fields added.
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

    // MARK: - Sprint 38 additions

    /// True when the composition object has `forced_on_flag` (bit 6 of PCS
    /// object_cropped_flag byte) set.  Forced subtitles must be displayed
    /// regardless of the user's subtitle-language preference (e.g. foreign-
    /// language inserts in an otherwise same-language film).
    let isForced: Bool

    /// Bounds of the WDS display window in video-space coordinates, if a
    /// Window Definition Segment was parsed for this display set.
    /// Used by PGSSubtitleView as a position fallback when objectRect.origin
    /// is (0, 0) and as a rendering context hint.
    let windowRect: CGRect?

    var hasImage: Bool { image != nil }
}
