// MARK: - PlayerLab / Subtitle / SubtitleSetupCoordinator
// Spring Cleaning SC5 — Subtitle wiring extracted from
// PlayerLabPlaybackController.
//
// Responsibilities:
//   • `reset()`            — clear both subtitle controllers before a new file
//   • `apply(mkvResult:)`  — wire tracks + cues from a parsed MKV/WebM container
//   • `onPlaybackEnded()`  — select-off both controllers when the stream ends
//
// NOT included here (stays on each individual controller per the spec):
//   • `subtitleController.update(forTime:)`
//   • `pgsController.update(forTime:)`
//
// `SubtitleSetupCoordinator` holds unowned (weak) references to both
// controllers, which are still owned and published by
// `PlayerLabPlaybackController`.  Because both controllers are
// `@MainActor` objects and the coordinator is called exclusively from
// `@MainActor` prepare() / stop() / onPlaybackEnded(), the coordinator
// itself is `@MainActor`-scoped.
//
// NOT production-ready. Debug / lab use only.

import Foundation

// MARK: - SubtitleSetupCoordinator

@MainActor
struct SubtitleSetupCoordinator {

    // MARK: - Stored references
    //
    // Both objects are owned by the controller; the coordinator only holds
    // a reference so it can call methods on them.

    private let srt: PlayerLabSubtitleController
    private let pgs: PGSSubtitleController

    // MARK: - Init

    init(srtController: PlayerLabSubtitleController,
         pgsController:  PGSSubtitleController) {
        self.srt = srtController
        self.pgs = pgsController
    }

    // MARK: - Lifecycle calls

    /// Clear both controllers. Called at the start of `prepare()` and from `stop()`.
    func reset() {
        srt.reset()
        pgs.reset()
    }

    /// Wire all subtitle data from a parsed MKV/WebM container.
    ///
    /// Mirrors the block that previously lived in the `case .mkv(let r):` branch
    /// of `prepare()`'s container-result switch.
    ///
    /// - SRT-compatible tracks → `srt` controller
    /// - PGS tracks + cues     → `pgs` controller
    ///
    /// No-ops for containers without subtitle tracks.
    func apply(mkvResult r: MKVPreparationResult) {
        // ── SRT subtitles ─────────────────────────────────────────────────────
        srt.setAvailableTracks(r.availableSubtitleTracks)
        if let subTrack = r.selectedSubtitleTrack, !r.subtitleCues.isEmpty {
            srt.loadCues(r.subtitleCues, for: subTrack)
        }

        // ── PGS subtitles ─────────────────────────────────────────────────────
        if let pgsTrack = r.selectedPGSTrack, !r.pgsCues.isEmpty {
            pgs.setAvailableTracks(r.availableSubtitleTracks)
            pgs.loadCues(r.pgsCues, for: pgsTrack)
        }
    }

    /// Deactivate both subtitle overlays when playback ends.
    /// Called from `onPlaybackEnded()`.
    func onPlaybackEnded() {
        srt.selectOff()
        pgs.selectOff()
    }
}
