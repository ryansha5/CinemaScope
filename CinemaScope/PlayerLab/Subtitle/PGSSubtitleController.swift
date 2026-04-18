// MARK: - PlayerLab / Subtitle / PGSSubtitleController
// Sprint 28 — Cue-timing manager for PGS bitmap subtitle overlay.
// Sprint 39 — clearCurrentCue(reason:) added for immediate seek clearing.
// Sprint 40 — Forced-cue auto-display: when all loaded cues carry isForced,
//             the controller shows them even if no track has been explicitly
//             selected (e.g. foreign-language insets in an English film).
//
// Mirrors PlayerLabSubtitleController structure: search-hint optimization,
// backwards-seek detection, same update semantics.
//
// NOT production-ready. Debug / lab use only.

import Foundation
import CoreMedia

@MainActor
final class PGSSubtitleController: ObservableObject {

    @Published private(set) var currentCue: PGSCue? = nil
    @Published private(set) var availableTracks: [SubtitleTrackDescriptor] = []
    @Published private(set) var selectedTrack: SubtitleTrackDescriptor? = nil

    private var cues: [PGSCue] = []
    private var searchHint: Int = 0

    // Sprint 40: set in loadCues() when every loaded cue has isForced == true.
    // When true, update(forTime:) bypasses the selectedTrack guard so forced
    // subtitles always appear regardless of user subtitle preferences.
    private var allCuesAreForced: Bool = false

    // MARK: - Track Management

    func setAvailableTracks(_ tracks: [SubtitleTrackDescriptor]) {
        self.availableTracks = tracks
    }

    func loadCues(_ newCues: [PGSCue], for track: SubtitleTrackDescriptor?) {
        self.cues       = newCues
        self.selectedTrack = track
        self.searchHint = 0
        self.currentCue = nil

        // Sprint 40: detect all-forced cue set (e.g. Japanese insets on a
        // Japanese-language Blu-ray).  Log once at load time so the decision
        // is visible in the debug log; no repeated noise during playback.
        let forced = !newCues.isEmpty && newCues.allSatisfy { $0.isForced }
        self.allCuesAreForced = forced
        if forced {
            fputs("[PGSSubtitleController] [Sprint40] "
                + "All \(newCues.count) cue(s) are forced — "
                + "enabling forced display regardless of track selection\n", stderr)
        }
    }

    func selectOff() {
        self.selectedTrack = nil
        self.currentCue = nil
    }

    // MARK: - Time Update

    func update(forTime time: TimeInterval) {
        guard !cues.isEmpty else {
            currentCue = nil
            return
        }

        // Sprint 40: show cues when a track is explicitly selected, OR when
        // every cue in the loaded set is forced (mandatory display).
        guard selectedTrack != nil || allCuesAreForced else {
            currentCue = nil
            return
        }

        // Backwards seek detection: reset searchHint if time goes backwards
        if let current = currentCue, time < current.startTime.seconds {
            searchHint = 0
        }

        // Search for cue at current time, starting from searchHint
        searchHint = max(0, min(searchHint, cues.count - 1))

        // Forward search from hint
        var found: PGSCue? = nil
        for i in searchHint..<cues.count {
            let cue = cues[i]
            if time >= cue.startTime.seconds && time < cue.endTime.seconds {
                found = cue
                searchHint = i
                break
            }
            if time < cue.startTime.seconds {
                break
            }
        }

        // If not found, try from beginning (in case searchHint skipped)
        if found == nil && searchHint > 0 {
            for i in 0..<searchHint {
                let cue = cues[i]
                if time >= cue.startTime.seconds && time < cue.endTime.seconds {
                    found = cue
                    searchHint = i
                    break
                }
            }
        }

        // Update currentCue only if it changed
        if let f = found, currentCue?.id != f.id {
            currentCue = f
        } else if found == nil {
            currentCue = nil
        }
    }

    // MARK: - Sprint 39: Seek clearing

    /// Immediately clears the currently displayed cue.
    ///
    /// Called during seek Phase 2 (flush) so no stale PGS frame lingers on
    /// screen between the flush and the first post-seek `update(forTime:)` call
    /// (which otherwise arrives up to 250 ms later).
    func clearCurrentCue(reason: String) {
        guard currentCue != nil else { return }
        fputs("[PGSSubtitleController] Clearing current cue — \(reason)\n", stderr)
        currentCue = nil
    }

    // MARK: - Reset

    func reset() {
        cues.removeAll()
        selectedTrack    = nil
        currentCue       = nil
        searchHint       = 0
        allCuesAreForced = false
    }
}
