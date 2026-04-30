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
    ///
    /// Sprint 73: raised from 3.0 → 10.0.
    ///
    /// Rationale: the initial scan covers ~8–10 s.  With 3.0 s the initial
    /// feedWindow loads only 3 s; when the buffer fell below lowWatermarkSeconds
    /// (10 s) on the very first feed-loop tick, a LOW WATERMARK refill fired
    /// immediately.  On slower connections or when competing with background-
    /// indexer HTTP traffic, that refill took > 3 s → real underrun → .buffering
    /// on the first tick after play().
    ///
    /// Raising to 10.0 s means the initial feedWindow always tries to load as
    /// many frames as the current index covers (up to 10 s).  Paired with
    /// waitForStartupBuffer() in PlayerLabHostView, the pre-play buffer reaches
    /// startupBufferSeconds before the clock starts — eliminating the immediate
    /// underrun entirely.
    let initialWindowSeconds: Double = 10.0

    /// Minimum pre-loaded buffer depth before play() should be called.
    ///
    /// Sprint 73: set above lowWatermarkSeconds (10.0) so that after
    /// waitForStartupBuffer() completes, the first feed-loop tick does NOT
    /// immediately see a LOW WATERMARK and fire a competing refill.
    let startupBufferSeconds: Double = 12.0

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

}
