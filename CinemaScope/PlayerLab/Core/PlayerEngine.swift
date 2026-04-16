import Combine

// MARK: - PlayerEngine
//
// Shared protocol that both the production PlaybackEngine and the experimental
// PlayerLabEngine conform to.  It exposes only the surface needed to drive the
// player UI — it intentionally omits:
//
//   • player: AVPlayer          — AVFoundation-specific; only ScopeCanvasView needs it
//   • aspectBucket / presentationMode / aspectRatioOverride
//                               — OSD/presentation details not needed by a generic engine
//   • setReportingContext(...)  — Emby-specific; not part of the abstract transport layer
//   • setRetryHandler(_:)       — implementation detail of the AVFoundation fallback path
//
// Any SwiftUI view or view-controller that currently depends on PlaybackEngine
// can be migrated to accept `any PlayerEngine` to make it engine-agnostic.

@MainActor
protocol PlayerEngine: AnyObject {

    // MARK: Observable state
    //
    // Conforming classes implement these as @Published properties.
    // Consumers that need Combine publishers can cast to the concrete type or
    // use onChange(of:) / task { for await ... in engine.$foo.values } patterns.

    var playbackState:       PlaybackState    { get }
    var currentTime:         Double           { get }
    var duration:            Double           { get }
    var nearingEnd:          Bool             { get }
    var videoDimensions:     VideoDimensions? { get }
    var effectiveContentRatio: Double         { get }
    var scopeUIEnabled:      Bool             { get }

    // MARK: Transport

    func load(url: URL, startTicks: Int64)
    func play()
    func pause()
    func stop()
    func seek(to fraction: Double)
    func togglePlayPause()

    // MARK: Context

    /// Called before every `load()` so the engine knows whether the scope UI is
    /// active and can resolve server-relative resources if needed.
    func setPlaybackContext(scopeUIEnabled: Bool, serverURL: String, itemId: String)
}

// MARK: - Default implementations

extension PlayerEngine {
    /// Convenience overload — start from the beginning when no tick offset is needed.
    func load(url: URL) {
        load(url: url, startTicks: 0)
    }
}
