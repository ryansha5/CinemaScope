// MARK: - PlayerLab / Subtitle / PGSSubtitleController
// Sprint 28 — Cue-timing manager for PGS bitmap subtitle overlay.
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

    // MARK: - Track Management

    func setAvailableTracks(_ tracks: [SubtitleTrackDescriptor]) {
        self.availableTracks = tracks
    }

    func loadCues(_ newCues: [PGSCue], for track: SubtitleTrackDescriptor?) {
        self.cues = newCues
        self.selectedTrack = track
        self.searchHint = 0
        self.currentCue = nil
    }

    func selectOff() {
        self.selectedTrack = nil
        self.currentCue = nil
    }

    // MARK: - Time Update

    func update(forTime time: TimeInterval) {
        guard !cues.isEmpty, selectedTrack != nil else {
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

    // MARK: - Reset

    func reset() {
        cues.removeAll()
        selectedTrack = nil
        currentCue = nil
        searchHint = 0
    }
}
