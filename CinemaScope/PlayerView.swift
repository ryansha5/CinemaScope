import SwiftUI
import AVFoundation
import AVKit

// MARK: - PlayerView

/// Wraps AVPlayerViewController for use in SwiftUI.
/// Using AVPlayerViewController (not VideoPlayer) gives us full control
/// over the player layer — essential for Sprint 2's scope canvas math.
struct PlayerView: UIViewControllerRepresentable {

    let engine: PlaybackEngine

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = engine.player

        // Sprint 1: standard video gravity.
        // Sprint 2 will replace this with scope-canvas presentation logic.
        vc.videoGravity = .resizeAspect

        // Hide system transport controls so we build our own OSD in Sprint 3.
        vc.showsPlaybackControls = true

        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Re-sync the player if the engine ever replaces it (future sprints).
        uiViewController.player = engine.player
    }
}
