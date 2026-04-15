import SwiftUI
import UIKit

// MARK: - PlayerContainerView

struct PlayerContainerView: UIViewControllerRepresentable {

    let item:     EmbyItem
    let engine:   PlaybackEngine
    let session:  EmbySession
    let onExit:   () -> Void
    /// Called when the user taps "Try Again" on the error screen.
    /// HomeView passes `{ play(item) }` so playback is fully re-initiated.
    let onRetry:  (() -> Void)?

    func makeUIViewController(context: Context) -> PlayerContainerViewController {
        PlayerContainerViewController(item: item, engine: engine, onExit: onExit, onRetry: onRetry)
    }

    func updateUIViewController(_ vc: PlayerContainerViewController, context: Context) {}
}

// MARK: - PlayerContainerViewController

final class PlayerContainerViewController: UIViewController {

    private let item:    EmbyItem
    private let engine:  PlaybackEngine
    private let onExit:  () -> Void
    private let onRetry: (() -> Void)?

    private var canvasVC:       ScopeCanvasViewController!
    private var osdHostVC:      UIHostingController<AnyView>?
    private var statusHostVC:   UIHostingController<AnyView>?   // loading / retrying / error
    private var osdVisible = false

    // Tracks how long select has been held
    private var selectPressStart: Date? = nil
    private let holdThreshold: TimeInterval = 0.4

    init(item: EmbyItem, engine: PlaybackEngine, onExit: @escaping () -> Void, onRetry: (() -> Void)?) {
        self.item    = item
        self.engine  = engine
        self.onExit  = onExit
        self.onRetry = onRetry
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

        // Observe all meaningful playback state transitions
        Task { @MainActor in
            for await state in engine.$playbackState.values {
                switch state {
                case .loading:
                    self.showStatusOverlay(.loading("Loading…"))
                case .retrying(let msg):
                    self.showStatusOverlay(.retrying(msg))
                case .playing, .paused:
                    self.removeStatusOverlay()
                case .failed(let msg):
                    self.showStatusOverlay(.error(msg))
                case .idle:
                    break
                }
            }
        }
    }

    // MARK: - Status overlay (loading / retrying / error)

    private func showStatusOverlay(_ state: PlayerStatusOverlay.OverlayState) {
        if let existing = statusHostVC {
            // Update state in place when already showing (e.g. loading → retrying)
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

        // Prevent OSD from sitting on top of the loading overlay
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
    //
    // Remote button strategy:
    //   Select (short tap)  → toggle OSD if hidden, or dismiss if visible
    //   Select (hold 0.4s)  → toggle play/pause (feels natural mid-movie)
    //   Play/Pause button   → always toggles play/pause
    //   Menu button         → exit player (or dismiss OSD first if visible)
    //
    // Status overlays (loading/error) capture focus themselves, so remote
    // presses during those states are handled by the SwiftUI overlay buttons.

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Don't intercept presses while a status overlay has focus
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
                if osdVisible {
                    hideOSD()
                } else {
                    exit()
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
        guard osdHostVC == nil, statusHostVC == nil else { return }
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
            onExit:        { [weak self] in self?.exit() }
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

// MARK: - PlayerStatusOverlay
//
// SwiftUI view shown over the player canvas for loading, retrying, and error states.
// Using SwiftUI here (rather than UIKit) gives us correct tvOS focus handling on buttons.

struct PlayerStatusOverlay: View {

    enum OverlayState: Equatable {
        case loading(String)
        case retrying(String)
        case error(String)
    }

    let state:   OverlayState
    let onRetry: (() -> Void)?
    let onExit:  () -> Void

    @FocusState private var focusedButton: OverlayButton?
    enum OverlayButton { case retry, exit }

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 28) {
                switch state {

                // ── Loading ────────────────────────────────────────
                case .loading(let msg):
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.6)
                        .tint(.white)
                    Text(msg)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))

                // ── Retrying ───────────────────────────────────────
                case .retrying(let msg):
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.6)
                        .tint(.white)
                    VStack(spacing: 8) {
                        Text(msg)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("This may take a moment.")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.45))
                    }

                // ── Error ──────────────────────────────────────────
                case .error(let msg):
                    Text("⚠️")
                        .font(.system(size: 56))
                    Text("Playback Error")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                    Text(msg)
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 640)

                    HStack(spacing: 24) {
                        if let onRetry {
                            OverlayActionButton(label: "Try Again",
                                               icon: "arrow.clockwise",
                                               isFocused: focusedButton == .retry) {
                                onRetry()
                            }
                            .focused($focusedButton, equals: .retry)
                        }

                        OverlayActionButton(label: "Go Back",
                                           icon: "chevron.left",
                                           isFocused: focusedButton == .exit) {
                            onExit()
                        }
                        .focused($focusedButton, equals: .exit)
                    }
                    .focusSection()
                    .onAppear {
                        // Default focus: retry if available, otherwise back
                        focusedButton = onRetry != nil ? .retry : .exit
                    }
                }
            }
        }
    }
}

// MARK: - OverlayActionButton

private struct OverlayActionButton: View {
    let label:     String
    let icon:      String
    let isFocused: Bool
    let action:    () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isFocused ? .black : .white)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(
                isFocused
                    ? Color.white
                    : Color.white.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
    }
}
