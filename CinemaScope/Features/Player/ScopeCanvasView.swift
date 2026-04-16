import SwiftUI
import AVFoundation
import Combine

struct ScopeCanvasView: UIViewControllerRepresentable {

    @ObservedObject var engine: PlaybackEngine

    func makeUIViewController(context: Context) -> ScopeCanvasViewController {
        ScopeCanvasViewController(engine: engine)
    }

    func updateUIViewController(_ vc: ScopeCanvasViewController, context: Context) {
        vc.updateLayout()
    }
}

final class ScopeCanvasViewController: UIViewController {

    private let engine: PlaybackEngine
    private let playerLayer = AVPlayerLayer()
    private var cancellables = Set<AnyCancellable>()

    init(engine: PlaybackEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.backgroundColor = UIColor.black.cgColor

        playerLayer.player = engine.player
        playerLayer.backgroundColor = UIColor.black.cgColor

        // Use .resizeAspectFill so AVFoundation zooms the stream to fill
        // the rect ScopeCanvasGeometry computes, preserving pixel aspect ratio.
        // Any stream content outside that rect (embedded letterbox/pillarbox bars)
        // is clipped by the layer's own bounds — no distortion, no double-scaling.
        // The frame is always sized for the *effective content* ratio, so the
        // "fill target" is already the correct shape; the gravity just handles
        // the zoom-crop when the raw stream has a different ratio than the content.
        playerLayer.videoGravity = .resizeAspectFill

        view.layer.addSublayer(playerLayer)

        // Subscribe to all three sources that can change the layout:
        //   presentationMode  — user switched Scope Safe ↔ Full Screen in OSD
        //   videoDimensions   — dimensions arrived from server stream
        //   aspectRatioOverride — user set a manual override in OSD
        Publishers.CombineLatest3(
            engine.$presentationMode,
            engine.$videoDimensions,
            engine.$aspectRatioOverride
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.updateLayout() }
        .store(in: &cancellables)

        // Also react to black-bar detection completing
        engine.$detectedContentRatio
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLayout() }
            .store(in: &cancellables)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayout()
    }

    func updateLayout() {
        guard view.bounds.size != .zero else { return }

        let screen       = view.bounds.size
        let contentRatio = engine.effectiveContentRatio   // respects override > detection > metadata
        let mode         = engine.presentationMode

        let videoRect = ScopeCanvasGeometry.videoRect(
            for: mode,
            contentRatio: contentRatio,
            in: screen
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = videoRect
        CATransaction.commit()

        print("[ScopeCanvas] mode=\(mode.label) ratio=\(String(format: "%.3f", contentRatio)) rect=\(videoRect)")
    }
}
