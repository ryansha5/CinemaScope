import SwiftUI
import UIKit

// MARK: - PlayerContainerView

struct PlayerContainerView: UIViewControllerRepresentable {

    let item:             EmbyItem
    let engine:           PlaybackEngine
    let session:          EmbySession
    let scopeUIEnabled:   Bool
    let autoplay:         Bool
    let onExit:           () -> Void
    /// Called when the user taps "Try Again" on the error screen.
    let onRetry:          (() -> Void)?
    /// Called when autoplay countdown completes or user taps "Play Next".
    let onPlayNext:       (() -> Void)?

    // MARK: - Backdrop URL

    private var backdropURL: URL? {
        guard let server = session.server else { return nil }
        if item.type == "Episode", let seriesId = item.seriesId {
            return URL(string: "\(server.url)/Items/\(seriesId)/Images/Backdrop?width=1920")
        }
        guard let tag = item.backdropImageTags?.first else { return nil }
        return URL(string: "\(server.url)/Items/\(item.id)/Images/Backdrop?tag=\(tag)&width=1920")
    }

    func makeUIViewController(context: Context) -> PlayerContainerViewController {
        PlayerContainerViewController(
            item: item, engine: engine,
            scopeUIEnabled: scopeUIEnabled,
            autoplay: autoplay,
            backdropURL: backdropURL,
            onExit: onExit, onRetry: onRetry, onPlayNext: onPlayNext
        )
    }

    func updateUIViewController(_ vc: PlayerContainerViewController, context: Context) {}
}

// MARK: - PlayerContainerViewController

final class PlayerContainerViewController: UIViewController {

    private let item:           EmbyItem
    private let engine:         PlaybackEngine
    private let scopeUIEnabled: Bool
    private let autoplay:       Bool
    private let backdropURL:    URL?
    private let onExit:         () -> Void
    private let onRetry:        (() -> Void)?
    private let onPlayNext:     (() -> Void)?

    private var canvasVC:         ScopeCanvasViewController!
    private var osdHostVC:        UIHostingController<AnyView>?
    private var statusHostVC:     UIHostingController<AnyView>?
    private var countdownHostVC:  UIHostingController<AnyView>?
    private var backdropImageView: UIImageView?
    private var osdVisible  = false
    /// Mirrors the AR pop-up open state from OSDView so we don't accidentally
    /// dismiss the OSD (and the menu) when the user navigates inside the menu.
    private var arMenuOpen  = false

    private var selectPressStart: Date? = nil
    private let holdThreshold: TimeInterval = 0.4

    init(item: EmbyItem, engine: PlaybackEngine, scopeUIEnabled: Bool, autoplay: Bool,
         backdropURL: URL?,
         onExit: @escaping () -> Void, onRetry: (() -> Void)?, onPlayNext: (() -> Void)?) {
        self.item           = item
        self.engine         = engine
        self.scopeUIEnabled = scopeUIEnabled
        self.autoplay       = autoplay
        self.backdropURL    = backdropURL
        self.onExit         = onExit
        self.onRetry        = onRetry
        self.onPlayNext     = onPlayNext
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Opt out of any automatic safe-area insets so the player truly fills
        // the screen — no overscan margin, no status-bar offset.
        additionalSafeAreaInsets = .zero
        view.insetsLayoutMarginsFromSafeArea = false

        // ── Canvas ─────────────────────────────────────────────────────────────
        canvasVC = ScopeCanvasViewController(engine: engine)
        addChild(canvasVC)
        view.addSubview(canvasVC.view)
        canvasVC.view.frame = view.bounds
        canvasVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasVC.didMove(toParent: self)

        // ── Backdrop splash ────────────────────────────────────────────────────
        // Added ABOVE the canvas so the item's artwork is visible during loading.
        // Fades out once the first video frame is rendered.
        // In scope UI mode the backdrop is constrained to the 2.39:1 canvas so
        // it doesn't bleed into the letterbox bars above and below.
        if let url = backdropURL {
            let iv = UIImageView()
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.alpha = 0
            iv.frame = backdropFrame
            // No autoresizingMask when scope-constrained — viewDidLayoutSubviews
            // recomputes the frame precisely. Full-screen mode can use the mask.
            if !scopeUIEnabled {
                iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            }
            view.insertSubview(iv, aboveSubview: canvasVC.view)
            backdropImageView = iv

            Task { @MainActor in
                if let cached = ImageCache.shared.image(for: url) {
                    iv.image = cached
                    UIView.animate(withDuration: 0.25) { iv.alpha = 0.85 }
                } else {
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let img = UIImage(data: data) else { return }
                    ImageCache.shared.store(img, for: url)
                    iv.image = img
                    UIView.animate(withDuration: 0.35) { iv.alpha = 0.85 }
                }
            }
        }

        // ── Observe playback state ─────────────────────────────────────────────
        Task { @MainActor in
            for await state in engine.$playbackState.values {
                switch state {
                case .loading:
                    self.showStatusOverlay(.loading("Loading…"))
                case .retrying(let msg):
                    self.showStatusOverlay(.retrying(msg))
                case .playing, .paused:
                    self.removeStatusOverlay()
                    if let iv = self.backdropImageView, iv.alpha > 0 {
                        UIView.animate(withDuration: 0.5, delay: 0.15) { iv.alpha = 0 }
                    }
                case .failed(let msg):
                    self.showStatusOverlay(.error(msg))
                case .idle:
                    break
                }
            }
        }

        // ── Autoplay countdown ─────────────────────────────────────────────────
        if autoplay && item.type == "Episode" && onPlayNext != nil {
            Task { @MainActor in
                for await nearing in engine.$nearingEnd.values {
                    if nearing { self.showCountdown() }
                    else       { self.removeCountdown() }
                }
            }
        }
    }

    // MARK: - Status overlay (loading / retrying / error)

    private func showStatusOverlay(_ state: PlayerStatusOverlay.OverlayState) {
        if let existing = statusHostVC {
            existing.rootView = AnyView(
                PlayerStatusOverlay(state: state,
                                    onRetry: onRetry,
                                    onExit: { [weak self] in self?.exit() })
            )
            return
        }

        let overlayView = PlayerStatusOverlay(
            state: state,
            onRetry: onRetry,
            onExit: { [weak self] in self?.exit() }
        )
        let hostVC = UIHostingController(rootView: AnyView(overlayView))
        hostVC.view.backgroundColor = .clear
        addChild(hostVC)
        view.addSubview(hostVC.view)
        hostVC.view.frame = view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostVC.didMove(toParent: self)
        statusHostVC = hostVC

        if osdVisible { hideOSD() }
    }

    private func removeStatusOverlay() {
        statusHostVC?.willMove(toParent: nil)
        statusHostVC?.view.removeFromSuperview()
        statusHostVC?.removeFromParent()
        statusHostVC = nil
    }

    private func exit() {
        engine.stop()
        onExit()
    }

    // MARK: - Autoplay countdown

    private func showCountdown() {
        guard countdownHostVC == nil else { return }
        let countdown = NextEpisodeCountdown(
            onPlayNext: { [weak self] in
                self?.removeCountdown()
                self?.engine.stop()
                self?.onPlayNext?()
            },
            onCancel: { [weak self] in
                self?.removeCountdown()
                self?.engine.suppressNearingEnd()
            }
        )
        let hostVC = UIHostingController(rootView: AnyView(countdown))
        hostVC.view.backgroundColor = .clear
        addChild(hostVC)
        if let osd = osdHostVC?.view {
            self.view.insertSubview(hostVC.view, aboveSubview: osd)
        } else {
            self.view.addSubview(hostVC.view)
        }
        hostVC.view.frame = self.view.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostVC.didMove(toParent: self)
        countdownHostVC = hostVC
    }

    private func removeCountdown() {
        countdownHostVC?.willMove(toParent: nil)
        countdownHostVC?.view.removeFromSuperview()
        countdownHostVC?.removeFromParent()
        countdownHostVC = nil
        becomeFirstResponder()
    }

    // MARK: - Layout

    /// The rect the backdrop image view should occupy.
    /// Scope UI: constrained to the 2.39:1 canvas (black bars stay black).
    /// Normal UI: full screen.
    private var backdropFrame: CGRect {
        scopeUIEnabled
            ? ScopeCanvasGeometry.canvasRect(in: view.bounds.size)
            : view.bounds
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep the scope-constrained backdrop in sync with the canvas rect
        // if bounds change (e.g. first layout pass, rotation).
        if scopeUIEnabled, let iv = backdropImageView {
            iv.frame = backdropFrame
        }
    }

    // MARK: - viewDidAppear

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

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard statusHostVC == nil else {
            super.pressesBegan(presses, with: event)
            return
        }
        for press in presses {
            switch press.type {
            case .select:
                selectPressStart = Date()
                return
            case .playPause:
                engine.togglePlayPause()
                return
            case .menu:
                if osdVisible { hideOSD() } else { exit() }
                return
            case .upArrow:
                if !osdVisible { showOSD() }
                return
            case .downArrow:
                // Don't close the OSD while the AR menu is open — the user is
                // navigating through the aspect ratio options, not dismissing.
                if osdVisible && !arMenuOpen { hideOSD() }
                return
            default:
                break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard statusHostVC == nil else {
            super.pressesEnded(presses, with: event)
            return
        }
        for press in presses {
            if let key = press.key {
                switch key.charactersIgnoringModifiers {
                case " ": engine.togglePlayPause(); return
                case "o", "O": toggleOSD(); return
                default: break
                }
            }
            if press.type == .select, let start = selectPressStart {
                let duration = Date().timeIntervalSince(start)
                selectPressStart = nil
                if duration >= holdThreshold { engine.togglePlayPause() }
                else                         { toggleOSD() }
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
        guard osdHostVC == nil, statusHostVC == nil else { return }
        osdVisible = true

        let osdView = OSDView(
            title:               item.name,
            bucket:              engine.aspectBucket,
            mode:                engine.presentationMode,
            playbackState:       engine.playbackState,
            currentTime:         engine.currentTime,
            duration:            engine.duration,
            aspectRatioOverride: engine.aspectRatioOverride,
            scopeUIEnabled:      scopeUIEnabled,
            onModeChange:  { [weak self] newMode in
                self?.engine.presentationMode = newMode
                self?.refreshOSD()
            },
            onAspectRatioChange: { [weak self] newOverride in
                self?.engine.setAspectRatioOverride(newOverride)
                self?.refreshOSD()
            },
            onPlayPause:   { [weak self] in self?.engine.togglePlayPause() },
            onSeek:        { [weak self] in self?.engine.seek(to: $0) },
            onDismiss:     { [weak self] in self?.hideOSD() },
            onExit:        { [weak self] in self?.exit() },
            onARMenuStateChange: { [weak self] open in self?.arMenuOpen = open }
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
        arMenuOpen = false          // reset since the SwiftUI view is being torn down
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

