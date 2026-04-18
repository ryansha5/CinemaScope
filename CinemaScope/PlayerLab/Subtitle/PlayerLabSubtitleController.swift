// MARK: - PlayerLab / Subtitle / PlayerLabSubtitleController
//
// Sprint 26 — Cue-timing manager for subtitle overlay.
//
// Responsibilities:
//   • Holds available subtitle track descriptors
//   • Holds the cue list for the currently selected track
//   • Exposes currentCue (updated by the time-tracking loop every 250 ms)
//   • Exposes selectedTrack so the view can reflect selection state
//
// Thread safety: all published properties must be mutated on @MainActor.
// PlayerLabPlaybackController calls update(forTime:) from its time-tracking task.
//
// NOT production-ready. Debug / lab use only.

import Foundation
import CoreMedia

@MainActor
final class PlayerLabSubtitleController: ObservableObject {

    // MARK: - Published

    /// The subtitle cue that should be displayed at the current playhead position.
    @Published private(set) var currentCue: SubtitleCue? = nil

    /// All subtitle tracks found in the current file (including unsupported codecs).
    @Published private(set) var availableTracks: [SubtitleTrackDescriptor] = []

    /// The currently active subtitle track.  nil = subtitles off.
    @Published private(set) var selectedTrack: SubtitleTrackDescriptor? = nil

    // MARK: - Private state

    /// Sorted cue list for the active track.
    private var cues: [SubtitleCue] = []

    /// Optimisation: last index where we found an active cue so we don't
    /// binary-search from 0 every tick.  Reset on seek (backwards time jump).
    private var searchHint: Int = 0

    // MARK: - Track management

    func setAvailableTracks(_ tracks: [SubtitleTrackDescriptor]) {
        availableTracks = tracks
    }

    /// Load cues for the given track.  Pass nil to turn subtitles off.
    func loadCues(_ newCues: [SubtitleCue], for track: SubtitleTrackDescriptor?) {
        cues         = newCues.sorted { $0.startTime.seconds < $1.startTime.seconds }
        selectedTrack = track
        currentCue   = nil
        searchHint   = 0
        fputs("[SubtitleController] loaded \(cues.count) cues for \(track?.displayLabel ?? "off")\n", stderr)
    }

    func selectOff() {
        cues          = []
        selectedTrack = nil
        currentCue    = nil
        searchHint    = 0
    }

    // MARK: - Playhead update (called from time-tracking loop)

    func update(forTime time: TimeInterval) {
        guard !cues.isEmpty else {
            if currentCue != nil { currentCue = nil }
            return
        }

        // Detect backwards jump (seek) — reset hint to avoid stale index
        if searchHint > 0,
           cues[searchHint - 1].startTime.seconds > time + 1.0 {
            searchHint = 0
        }

        // Advance hint past cues that have definitively ended
        while searchHint < cues.count {
            let cue = cues[searchHint]
            let endSec = cue.endTime.isValid ? cue.endTime.seconds : cue.startTime.seconds + 5.0
            if endSec <= time { searchHint += 1 }
            else { break }
        }

        // Check if the hint cue is active right now
        if searchHint < cues.count {
            let cue = cues[searchHint]
            if cue.startTime.seconds <= time {
                if currentCue?.id != cue.id { currentCue = cue }
                fputs("[SubtitleController] Cue on-screen: \"\(cue.text.prefix(60))\"\n", stderr)
                return
            }
        }

        // Nothing active at this position
        if currentCue != nil { currentCue = nil }
    }

    // MARK: - Full reset (on stop / new file)

    func reset() {
        cues          = []
        availableTracks = []
        selectedTrack = nil
        currentCue    = nil
        searchHint    = 0
    }
}
