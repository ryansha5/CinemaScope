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
    let targetBufferSeconds:  Double = 8.0

    /// Low-watermark that triggers a background refill in the normal feed path.
    let lowWatermarkSeconds:  Double = 2.0

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
