import SwiftUI
import UIKit

// MARK: - PlayerContainerView

struct PlayerContainerView: UIViewControllerRepresentable {

    let item:    EmbyItem
    let engine:  PlaybackEngine
    let session: EmbySession
    let onExit:  () -> Void

    func makeUIViewController(context: Context) -> PlayerContainerViewController {
        PlayerContainerViewController(item: item, engine: engine, onExit: onExit)
    }

    func updateUIViewController(_ vc: PlayerContainerViewController, context: Context) {}
}

// MARK: - PlayerContainerViewController

final class PlayerContainerViewController: UIViewController {

    private let item:   EmbyItem
    private let engine: PlaybackEngine
    private let onExit: () -> Void

    private var canvasVC:  ScopeCanvasViewController!
    private var osdHostVC: UIHostingController<AnyView>?
    private var osdVisible = false

    // Tracks how long select has been held
    private var selectPressStart: Date? = nil
    private let holdThreshold: TimeInterval = 0.4

    init(item: EmbyItem, engine: PlaybackEngine, onExit: @escaping () -> Void) {
        self.item   = item
        self.engine = engine
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        canvasVC = ScopeCanvasViewController(engine: engine)
        addChild(canvasVC)
        view.addSubview(canvasVC.view)
        canvasVC.view.frame = view.bounds
        canvasVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasVC.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - Simulator keyboard shortcuts

    override var keyCommands: [UIKeyCommand]? {[
        UIKeyCommand(input: " ",  modifierFlags: [], action: #selector(keyPlayPause)),
        UIKeyCommand(input: "o",  modifierFlags: [], action: #selector(keyToggleOSD)),
    ]}

    @objc private func keyPlayPause() { engine.togglePlayPause() }
    @objc private func keyToggleOSD() { toggleOSD() }

    // MARK: - Remote press handling
    //
    // Remote button strategy:
    //   Select (short tap)  → toggle OSD if hidden, or dismiss if visible
    //   Select (hold 0.4s)  → toggle play/pause (feels natural mid-movie)
    //   Play/Pause button   → always toggles play/pause
    //   Menu button         → exit player
    //
    // We measure the press duration ourselves in pressesBegan/pressesEnded
    // rather than using gesture recognisers, which are unreliable on the
    // new clickpad-style Siri Remote.

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            switch press.type {
            case .select:
                // Record when select went down so we can measure hold duration
                selectPressStart = Date()
                return
            case .playPause:
                engine.togglePlayPause()
                return
            case .menu:
                if osdVisible {
                    // First menu press dismisses OSD
                    hideOSD()
                } else {
                    engine.pause()
                    onExit()
                }
                return
            case .upArrow:
                if !osdVisible { showOSD() }
                return
            case .downArrow:
                if osdVisible { hideOSD() }
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            // Keyboard fallback for Simulator
            if let key = press.key {
                switch key.charactersIgnoringModifiers {
                case " ": engine.togglePlayPause(); return
                case "o", "O": toggleOSD(); return
                default: break
                }
            }

            // Select: short tap = OSD toggle, hold = play/pause
            if press.type == .select, let start = selectPressStart {
                let duration = Date().timeIntervalSince(start)
                selectPressStart = nil
                if duration >= holdThreshold {
                    engine.togglePlayPause()
                } else {
                    toggleOSD()
                }
                return
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        selectPressStart = nil
        super.pressesCancelled(presses, with: event)
    }

    // MARK: - OSD

    private func toggleOSD() { osdVisible ? hideOSD() : showOSD() }

    private func showOSD() {
        guard osdHostVC == nil else { return }
        osdVisible = true

        let osdView = OSDView(
            title:         item.name,
            bucket:        engine.aspectBucket,
            mode:          engine.presentationMode,
            playbackState: engine.playbackState,
            currentTime:   engine.currentTime,
            duration:      engine.duration,
            onModeChange:  { [weak self] mode in
                self?.engine.presentationMode = mode
                self?.refreshOSD()
            },
            onPlayPause:   { [weak self] in self?.engine.togglePlayPause() },
            onSeek:        { [weak self] in self?.engine.seek(to: $0) },
            onDismiss:     { [weak self] in self?.hideOSD() },
            onExit:        { [weak self] in
                self?.engine.pause()
                self?.onExit()
            }
        )

        let hostVC = UIHostingController(rootView: AnyView(osdView))
        hostVC.view.backgroundColor = .clear
        addChild(hostVC)
        view.addSubview(hostVC.view)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostVC.didMove(toParent: self)
        osdHostVC = hostVC
    }

    private func hideOSD() {
        osdVisible = false
        osdHostVC?.willMove(toParent: nil)
        osdHostVC?.view.removeFromSuperview()
        osdHostVC?.removeFromParent()
        osdHostVC = nil
        becomeFirstResponder()
    }

    private func refreshOSD() {
        guard osdVisible else { return }
        hideOSD()
        showOSD()
    }
}
