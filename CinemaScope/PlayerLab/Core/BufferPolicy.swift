// MARK: - PlayerLab / Core / BufferPolicy
// Spring Cleaning SC6 — Buffer policy constants + feed-decision helpers.
// Extracted from PlayerLabPlaybackController (Sprints 17, 19).
//
// Owns:
//   • All numeric buffer thresholds (initial window, target, low-watermark, etc.)
//   • Log-cycle interval constants
//   • Boolean helpers that encapsulate threshold comparisons
//
// The controller replaces its six `private let` constants with
// `private let policy = BufferPolicy()` and queries helpers for every
// threshold comparison.  No behaviour changes; only consolidation.
//
// `BufferPolicy` is a plain value type (struct) with no dependencies on
// any PlayerLab type.  It is safe to use from any isolation context.
//
// NOT production-ready. Debug / lab use only.

import Foundation

// MARK: - BufferPolicy

struct BufferPolicy {

    // MARK: - Window / target constants

    /// Seconds of video to pre-load before reporting .ready.
    let initialWindowSeconds: Double = 3.0

    /// Desired buffer depth during normal playback.
    /// Sprint 58: raised from 8.0 → 15.0 to stay above the new 10.0 s low-watermark.
    let targetBufferSeconds:  Double = 15.0

    /// Low-watermark that triggers a background refill in the normal feed path.
    ///
    /// Sprint 55: raised from 2.0 → 5.0 to prevent audio underrun.
    /// Sprint 58: raised from 5.0 → 10.0.
    ///
    /// Rationale: Gap-tolerant HTTP coalescing (Sprint 57) collapses an entire
    /// 10 s refill batch into 1–2 HTTP requests.  For high-bitrate HEVC content
    /// (100 KB+ frames, ~2 MB/s average), a single refill batch can be 15–20 MB.
    /// At 5 MB/s download throughput (typical over LAN on the tvOS simulator),
    /// that batch takes ~4 s to download.
    ///
    /// The feed loop fires at most every ~1 s.  With the old 5.0 s watermark, the
    /// actual buffer when the download starts can be as low as 4.0 s.  A 4 s
    /// download drains the buffer to ≈ 0 s → underrun → display layer discards
    /// "late" frames → visible distortion.
    ///
    /// With the new 10.0 s watermark, the actual buffer at download start is ≥ 9 s.
    /// A 4 s download leaves ≥ 5 s in the buffer — safely above the 0.5 s underrun
    /// threshold even for very large high-bitrate refill batches.
    let lowWatermarkSeconds:  Double = 10.0

    /// Minimum seconds to request per feed call (guards against tiny chunks
    /// when the deficit is very small).
    let feedChunkSeconds:     Double = 2.0

    // MARK: - Underrun / recovery thresholds

    /// Buffer depth at or below which the controller enters .buffering.
    let underrunThreshold:    Double = 0.5

    /// Buffer depth at or above which the controller exits .buffering and
    /// resumes the synchronizer clock.
    let resumeThreshold:      Double = 1.5

    /// Minimum residual buffer at end-of-stream before triggering
    /// onPlaybackEnded(); guards against premature termination while the
    /// renderer drains the last frames.
    let eosMinBuffer:         Double = 0.5

    // MARK: - Pending-lag pause thresholds (Sprint 60)

    /// `actualBuffered` below which a PENDING-LAG condition triggers a clock
    /// pause.  Equal to `resumeThreshold` so the guard fires before the normal
    /// underrun path but at the same perceived depth — the difference is that a
    /// PENDING-LAG pause skips HTTP fetching (pending queue is already full) and
    /// waits for `pendingLagResumeThreshold` to confirm the layer has drained.
    let pendingLagPauseThreshold:  Double = 1.5

    /// `actualBuffered` at or above which the controller exits a PENDING-LAG
    /// pause and restores the synchronizer clock.  Higher than `resumeThreshold`
    /// to ensure the layer has drained enough of the pending-queue backlog before
    /// the clock advances again.
    let pendingLagResumeThreshold: Double = 2.5

    // MARK: - Log-cycle intervals

    /// Feed-loop cycles between periodic status log lines (normal playback).
    let periodicLogInterval:  Int = 10

    /// Feed-loop cycles between status log lines while buffering.
    let bufferingLogInterval: Int = 5

    // MARK: - Decision helpers

    /// `true` when the demuxer has no more samples to deliver **and** the
    /// renderer buffer has drained below `eosMinBuffer`.
    func isEndOfStream(isAtEOS: Bool, bufferedSeconds: Double) -> Bool {
        isAtEOS && bufferedSeconds < eosMinBuffer
    }

    /// `true` when the buffer has fallen below the underrun threshold.
    /// Used in .playing to decide whether to enter .buffering.
    func isUnderrun(bufferedSeconds: Double) -> Bool {
        bufferedSeconds < underrunThreshold
    }

    /// `true` when the buffer has recovered above the resume threshold.
    /// Used in .buffering to decide whether to restore the clock.
    func isRecovered(bufferedSeconds: Double) -> Bool {
        bufferedSeconds >= resumeThreshold
    }

    /// `true` when the buffer has fallen below the low-watermark.
    /// Used in normal .playing to decide whether to trigger a background refill.
    func isLowWatermark(bufferedSeconds: Double) -> Bool {
        bufferedSeconds < lowWatermarkSeconds
    }

    /// Seconds of media to request on the next refill call.
    ///
    /// Returns `max(targetBufferSeconds − currentlyBuffered, feedChunkSeconds)`
    /// so that small deficits still request at least `feedChunkSeconds` and
    /// large deficits fill efficiently to the target.
    func refillSeconds(currentlyBuffered: Double) -> Double {
        max(targetBufferSeconds - currentlyBuffered, feedChunkSeconds)
    }

    /// `true` when a PENDING-LAG clock-pause should be triggered.
    ///
    /// All three conditions must hold simultaneously:
    ///   - `actualBuffered < pendingLagPauseThreshold` — layer depth is critically low
    ///   - `pendingQueueCount > 0`                    — frames are queued but not yet at the layer
    ///   - `lag > 1.0`                                — feeder tail is >1 s ahead of the layer
    ///
    /// When true, the synchronizer clock should be paused.  The pending frames
    /// will drain into the layer via `requestMediaDataWhenReady` while rate=0;
    /// no new HTTP fetch is needed until `actualBuffered < lowWatermarkSeconds`.
    func isPendingLagPause(actualBuffered: Double, pendingQueueCount: Int, lag: Double) -> Bool {
        actualBuffered < pendingLagPauseThreshold && pendingQueueCount > 0 && lag > 1.0
    }
}
