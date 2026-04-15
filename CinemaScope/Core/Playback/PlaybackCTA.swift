import Foundation

// MARK: - PlaybackCTA
//
// Single source of truth for the Play / Resume / Restart decision.
// Apply this everywhere a primary playback action is shown:
//   • Movie and episode detail pages
//   • Continue Watching row tap behaviour
//   • Any future "Up Next" or home-level CTA
//
// Rules:
//   resumeThreshold  = max(10 s, 1% of runtime)
//   finishedThreshold = 97% of runtime
//
//   ticks == 0              → .play          (never started)
//   ticks < resumeThreshold → .play          (negligible progress — treat as new)
//   ticks ≥ finishedThreshold → .play        (effectively finished — offer fresh start)
//   otherwise               → .resume(from:) (meaningful progress — offer Resume + Restart)

enum PlaybackCTA: Equatable {

    /// No meaningful prior progress — show a single "Play" button.
    case play

    /// Meaningful progress — show "Resume" (primary) and "Restart" (secondary).
    /// `from` is the tick position to resume at.
    case resume(from: Int64)

    // MARK: - Thresholds

    /// Minimum elapsed time before we consider progress "meaningful".
    static let resumeThresholdSeconds: Double = 10.0          // 10 seconds

    /// Minimum elapsed percentage before we consider progress "meaningful".
    static let resumeThresholdFraction: Double = 0.01         // 1 % of runtime

    /// If position is at or beyond this fraction the item is "effectively finished".
    static let finishedThresholdFraction: Double = 0.97       // 97 % of runtime

    // MARK: - Factory

    /// Derive the correct CTA state from an `EmbyItem`'s stored user-data.
    ///
    /// Safe to call with items that have no runtime or no userData — defaults to `.play`.
    static func state(for item: EmbyItem) -> PlaybackCTA {
        let ticks      = item.userData?.playbackPositionTicks ?? 0
        let totalTicks = item.runTimeTicks ?? 0

        // Nothing played
        guard ticks > 0 else { return .play }

        // Resume threshold: max(10 s, 1 % of runtime) expressed in ticks
        let tenSecondTicks = Int64(resumeThresholdSeconds * 10_000_000)
        let onePercentTicks = totalTicks > 0
            ? Int64(Double(totalTicks) * resumeThresholdFraction)
            : Int64(0)
        let resumeThreshold = max(tenSecondTicks, onePercentTicks)

        // Finished threshold: 97 % of runtime
        // If we have no runtime info, never auto-dismiss as finished.
        let finishedThreshold: Int64 = totalTicks > 0
            ? Int64(Double(totalTicks) * finishedThresholdFraction)
            : Int64.max

        if ticks < resumeThreshold  { return .play }   // negligible — treat as new
        if ticks >= finishedThreshold { return .play }  // done — offer fresh start

        return .resume(from: ticks)
    }

    // MARK: - Convenience

    /// The tick position to pass to `PlaybackEngine.load(startTicks:)` for the primary action.
    var primaryStartTicks: Int64 {
        switch self {
        case .play:            return 0
        case .resume(let t):   return t
        }
    }

    /// Whether a secondary "Restart" button should be shown.
    var showsRestart: Bool {
        if case .resume = self { return true }
        return false
    }

    /// Human-readable "Resuming from X" label, nil when not resumable.
    var resumeLabel: String? {
        guard case .resume(let t) = self else { return nil }
        let totalSeconds = Int(t / 10_000_000)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "Resuming from %d:%02d:%02d", h, m, s)
        } else {
            return String(format: "Resuming from %d:%02d", m, s)
        }
    }

    // MARK: - Continue Watching visibility

    /// Returns true if this item should appear in a Continue Watching row.
    ///
    /// Criteria: there must be meaningful progress that hasn't finished.
    /// This mirrors the `.resume` state — if CTA is `.play` for any reason,
    /// the item does not belong in Continue Watching.
    static func shouldShowInContinueWatching(_ item: EmbyItem) -> Bool {
        if case .resume = state(for: item) { return true }
        return false
    }
}
