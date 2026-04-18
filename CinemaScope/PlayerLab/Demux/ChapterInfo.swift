// MARK: - PlayerLab / Demux / ChapterInfo
//
// Sprint 27 — Chapter metadata model.
// Shared across container types (MKV chapters are the primary source;
// MP4 chapter tracks can be added in a future sprint).
//
// Timestamps are always stored as CMTime (seconds domain).
// MKV stores chapter start/end in absolute nanoseconds from the beginning
// of content — independent of TimecodeScale.

import Foundation
import CoreMedia

struct ChapterInfo: Identifiable {

    /// 0-based chapter index within the edition.
    let id:        Int

    /// Human-readable chapter title.
    /// Falls back to "Chapter N" when no ChapString element is present.
    let title:     String

    /// Absolute presentation time of the chapter start.
    let startTime: CMTime

    /// Absolute presentation time of the chapter end.
    /// nil when not explicitly specified by the container; callers may derive
    /// it from the next chapter's startTime.
    let endTime:   CMTime?
}
