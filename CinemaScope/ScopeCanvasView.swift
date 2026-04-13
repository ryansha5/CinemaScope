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
        // Remove any default white/grey background the system might inject
        view.layer.contentsGravity = .resizeAspect
        playerLayer.player = engine.player
        playerLayer.backgroundColor = UIColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)

        Publishers.CombineLatest(
            engine.$presentationMode,
            engine.$videoDimensions
        )
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
        let contentRatio = engine.videoDimensions?.aspectRatio ?? AspectBucket.scopeRatio
        let mode         = engine.presentationMode

        // Geometry computes the exact rect for this mode and ratio.
        // We give that rect to the layer — no gravity scaling needed.
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
