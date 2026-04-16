import Foundation
import Combine

// MARK: - PlayerLabEngine
//
// ⚠️  EXPERIMENTAL — NOT wired to any production code path.
//
// This is a no-op stub that satisfies the PlayerEngine protocol.  It exists so
// that:
//
//   1. The protocol compiles and the folder structure is in place.
//   2. Future work can fill in real demux / decode logic method-by-method without
//      touching PlaybackEngine.swift.
//   3. A test harness (see Diagnostics/) can instantiate PlayerLabEngine and
//      verify protocol conformance and state transitions independently of AVPlayer.
//
// Current status:
//   • State properties publish their default values and never change.
//   • Transport methods are no-ops.
//   • No AVFoundation, no VideoToolbox, no custom renderer — those come later.
//
// DO NOT route production playback through this class.

@MainActor
final class PlayerLabEngine: ObservableObject, PlayerEngine {

    // MARK: - PlayerEngine state

    @Published private(set) var playbackState:        PlaybackState    = .idle
    @Published private(set) var currentTime:          Double           = 0
    @Published private(set) var duration:             Double           = 0
    @Published private(set) var nearingEnd:           Bool             = false
    @Published private(set) var videoDimensions:      VideoDimensions? = nil
    @Published private(set) var scopeUIEnabled:       Bool             = false

    // effectiveContentRatio mirrors PlaybackEngine's logic:
    // no override and no detected ratio → default to scope ratio.
    var effectiveContentRatio: Double {
        videoDimensions?.aspectRatio ?? AspectBucket.scopeRatio
    }

    // MARK: - Internal context (set by setPlaybackContext)

    private var serverURL: String = ""
    private var itemId:    String = ""

    // MARK: - Init

    init() {}

    // MARK: - PlayerEngine: Transport (all no-ops for now)

    func load(url: URL, startTicks: Int64) {
        // TODO: Sprint N — open URL via custom IO layer (PlayerLab/IO/)
        playbackState = .loading
        // Immediately drop back to idle so callers can observe the transition.
        playbackState = .idle
    }

    func play() {
        // TODO: Sprint N — signal decoder / renderer to begin presentation
    }

    func pause() {
        // TODO: Sprint N — pause presentation clock
    }

    func stop() {
        // TODO: Sprint N — tear down pipeline
        playbackState = .idle
        currentTime   = 0
        duration      = 0
        nearingEnd    = false
    }

    func seek(to fraction: Double) {
        // TODO: Sprint N — seek to fraction * duration
    }

    func togglePlayPause() {
        // TODO: Sprint N — toggle based on playbackState
    }

    // MARK: - PlayerEngine: Context

    func setPlaybackContext(scopeUIEnabled: Bool, serverURL: String, itemId: String) {
        self.scopeUIEnabled = scopeUIEnabled
        self.serverURL      = serverURL
        self.itemId         = itemId
    }
}
