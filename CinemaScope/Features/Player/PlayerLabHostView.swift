// MARK: - Features / Player / PlayerLabHostView
// Sprint 42 — Production PlayerLab wrapper for HomeView.
// Sprint 44 — Auto-play next: 5-second countdown overlay when playback ends.
//
// Wraps PlayerLabPlaybackController in a production-quality full-screen player
// view. Serves as the handoff layer between the routing decision (Sprint 41/43)
// and actual playback.
//
// Responsibilities:
//   • Displays a loading screen (item backdrop) while prepare() runs.
//   • Seeks to the resume position (startTicks) once .ready.
//   • Wires controller.onFallbackRequired so audio incompatibilities trigger a
//     clean handoff back to AVPlayer via onFallback(_:).
//   • When playback reaches .ended, calls fetchNextCandidate() concurrently
//     with a 5-second countdown overlay.  At zero, fires onPlayNext.
//   • User can cancel the auto-play countdown at any time.
//   • Provides a minimal transport bar (exit, seek ±30s, play/pause, progress).
//   • Does NOT contain any debug logging UI — that lives in PlayerLabPlayerView.
//
// NOT production-ready — used progressively as confidence grows across sprints.

import SwiftUI

// MARK: - AutoPlayCandidate

/// Returned by the `fetchNextCandidate` closure — carries the next item to
/// present in the countdown overlay plus a pre-resolved backdrop image URL.
struct AutoPlayCandidate {
    let item:        EmbyItem
    let backdropURL: URL?
}

// MARK: - PlayerLabHostView

struct PlayerLabHostView: View {

    // MARK: - Inputs

    let url:         URL
    let startTicks:  Int64
    let itemName:    String
    let backdropURL: URL?
    let onExit:      () -> Void
    let onFallback:  (String) -> Void

    // Sprint 44: optional auto-play next support.
    // When both are non-nil, a 5-second countdown overlay is shown at end-of-file.
    var fetchNextCandidate: (() async -> AutoPlayCandidate?)? = nil
    var onPlayNext:         ((EmbyItem) -> Void)?             = nil

    // MARK: - State

    @StateObject private var controller = PlayerLabPlaybackController()

    // Sprint 44 — countdown state
    @State private var nextCandidate:     AutoPlayCandidate? = nil
    @State private var autoPlayCountdown: Int?               = nil
    /// Countdown tick task — cancellation stops the countdown and hides the overlay.
    @State private var countdownTask:     Task<Void, Never>? = nil
    /// Parallel fetch task — cancelled together with countdownTask.
    @State private var candidateTask:     Task<AutoPlayCandidate?, Never>? = nil

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // ── Video layer ──────────────────────────────────────────────────
            PlayerLabDisplayView(renderer: controller.renderer)
                .ignoresSafeArea()
                .focusable(false)
                .opacity(isVideoVisible ? 1 : 0)
                .animation(.easeIn(duration: 0.3), value: isVideoVisible)

            // ── Text subtitle overlay ────────────────────────────────────────
            SubtitleView(cue: controller.subtitleController.currentCue)
                .ignoresSafeArea()
                .opacity(isVideoVisible ? 1 : 0)

            // ── PGS bitmap subtitle overlay ──────────────────────────────────
            PGSSubtitleView(cue: controller.pgsController.currentCue)
                .ignoresSafeArea()
                .opacity(isVideoVisible ? 1 : 0)

            // ── Loading / error overlay ──────────────────────────────────────
            if controller.state == .loading {
                loadingOverlay
                    .transition(.opacity)
            }

            // ── Auto-play countdown overlay (Sprint 44) ──────────────────────
            if autoPlayCountdown != nil {
                countdownOverlay
                    .transition(.opacity)
                    .zIndex(10)
            }

            // ── Transport ────────────────────────────────────────────────────
            VStack(spacing: 0) {
                Spacer()
                transportBar
            }
            .ignoresSafeArea(edges: .bottom)
            // Hide transport while countdown is showing — countdown has its own Cancel
            .opacity(autoPlayCountdown != nil ? 0 : 1)
        }
        .task {
            // Sprint 44: First Frame Mode — set before prepare() so the debug
            // path activates on the very first call to prepare().
            controller.firstFrameMode = AppSettings.shared.playerLabFirstFrameMode

            // Wire fallback before prepare() so it fires during audio classification.
            var fallbackFired = false
            controller.onFallbackRequired = { reason in
                fallbackFired = true
                onFallback(reason)
            }

            await controller.prepare(url: url)

            // If onFallbackRequired already fired, do nothing — the host is
            // handling the handoff. If prepare() failed for another reason,
            // also ask the host to fall back.
            guard !fallbackFired else { return }
            guard controller.state == .ready else {
                if case .failed(let msg) = controller.state {
                    onFallback("prepare failed: \(msg)")
                }
                return
            }

            // ── Seek to resume position ──────────────────────────────────────
            if startTicks > 0, controller.duration > 0 {
                let resumeSeconds = Double(startTicks) / 10_000_000.0
                let fraction      = min(1, max(0, resumeSeconds / controller.duration))
                if fraction > 0.001 {
                    await controller.seek(toFraction: fraction)
                }
            }

            controller.play()
        }
        // Sprint 44: kick off countdown when playback reaches .ended
        .onChange(of: controller.state) { _, newState in
            if newState == .ended {
                startAutoPlay()
            }
        }
        // Cancel any in-flight tasks when the view disappears
        .onDisappear {
            cancelAutoPlay()
        }
    }

    // MARK: - Derived

    private var isVideoVisible: Bool {
        switch controller.state {
        case .loading: return false
        default:       return true
        }
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        ZStack {
            if let backdropURL {
                AsyncImage(url: backdropURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .ignoresSafeArea()
                            .overlay(Color.black.opacity(0.6))
                    default:
                        Color.black.ignoresSafeArea()
                    }
                }
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(2)
                    .tint(.white)
                Text(itemName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
            }
        }
    }

    // MARK: - Auto-Play Countdown Overlay (Sprint 44)

    private var countdownOverlay: some View {
        ZStack {
            // Semi-transparent dimmer over the frozen last frame
            Color.black.opacity(0.80).ignoresSafeArea()

            // Next-item backdrop behind the UI (fades in once fetch completes)
            if let url = nextCandidate?.backdropURL {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill().ignoresSafeArea()
                            .overlay(Color.black.opacity(0.55))
                    }
                }
                .transition(.opacity)
                .animation(.easeIn(duration: 0.4), value: nextCandidate?.item.id)
            }

            VStack(spacing: 28) {

                // "UP NEXT" eyebrow label
                Text("UP NEXT")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.55))

                // Next item title — shows a spinner until the fetch resolves
                if let candidate = nextCandidate {
                    Text(candidate.item.name)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 80)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .animation(.easeOut(duration: 0.3), value: nextCandidate?.item.id)
                } else {
                    // Still fetching
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white.opacity(0.6))
                        .scaleEffect(1.4)
                }

                // Circular countdown ring + number
                if let count = autoPlayCountdown {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.15), lineWidth: 5)
                            .frame(width: 80, height: 80)
                        // Animating progress ring
                        Circle()
                            .trim(from: 0, to: CGFloat(count) / 5.0)
                            .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .frame(width: 80, height: 80)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.9), value: count)
                        Text("\(count)")
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                }

                // Cancel button
                Button {
                    cancelAutoPlay()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.white.opacity(0.25), lineWidth: 1)
                        )
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Transport Bar

    private var transportBar: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Progress bar (shown once duration is known)
            if controller.duration > 0 {
                progressBar
                    .padding(.horizontal, 40)
                    .padding(.bottom, 10)
            }

            // Control row
            HStack(spacing: 28) {

                // Exit
                Button {
                    controller.stop()
                    onExit()
                } label: {
                    Label("Done", systemImage: "xmark.circle.fill")
                        .font(.system(size: 19, weight: .semibold))
                }

                // Seek −30 s
                Button { seekBy(-30) } label: {
                    Label("−30s", systemImage: "gobackward.30")
                        .font(.system(size: 19, weight: .semibold))
                }
                .disabled(!controller.state.canSeek || controller.duration == 0)

                // Play / Pause
                Button(action: togglePlayPause) {
                    Label(
                        controller.state == .playing ? "Pause" : "Play",
                        systemImage: controller.state == .playing ? "pause.fill" : "play.fill"
                    )
                    .font(.system(size: 19, weight: .semibold))
                }
                .disabled(!controller.state.canPlay && !controller.state.canPause)

                // Seek +30 s
                Button { seekBy(30) } label: {
                    Label("+30s", systemImage: "goforward.30")
                        .font(.system(size: 19, weight: .semibold))
                }
                .disabled(!controller.state.canSeek || controller.duration == 0)

                Spacer()

                // Status
                Text(controller.state.statusLabel)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 18)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        let fraction = controller.duration > 0
            ? min(1, max(0, controller.currentTime / controller.duration))
            : 0.0

        return VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.2))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: max(0, geo.size.width * fraction), height: 4)
                }
            }
            .frame(height: 4)

            HStack {
                Text(formatTime(controller.currentTime))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(formatTime(controller.duration))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Auto-Play Logic (Sprint 44)

    private func startAutoPlay() {
        // Only fire if auto-play is configured and not already running
        guard fetchNextCandidate != nil, onPlayNext != nil else { return }
        guard autoPlayCountdown == nil, countdownTask == nil else { return }
        guard let fetchFn = fetchNextCandidate else { return }

        autoPlayCountdown = 5

        // Launch fetch in parallel with the countdown.
        // Stored so we can cancel it if the user taps Cancel.
        let cTask = Task<AutoPlayCandidate?, Never> { await fetchFn() }
        candidateTask = cTask

        // Observer: updates nextCandidate as soon as the fetch resolves, or
        // cancels the countdown silently if there is nothing to play next.
        Task { @MainActor in
            let result = await cTask.value
            guard autoPlayCountdown != nil else { return }  // already cancelled
            if let result {
                withAnimation { nextCandidate = result }
            } else {
                // Nothing to play next — dismiss countdown without firing onPlayNext
                cancelAutoPlay()
            }
        }

        // Countdown: ticks 5 → 4 → 3 → 2 → 1 with 1-second sleeps.
        // Cancelling this task (via cancelAutoPlay) stops the whole sequence.
        countdownTask = Task { @MainActor in
            for tick in stride(from: 5, through: 1, by: -1) {
                autoPlayCountdown = tick
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    // Cancelled — cleanup already handled by cancelAutoPlay()
                    return
                }
            }

            // Countdown finished — await fetch result (usually already done)
            let candidate = await cTask.value
            autoPlayCountdown = nil
            countdownTask     = nil
            candidateTask     = nil
            nextCandidate     = nil

            if let candidate {
                onPlayNext?(candidate.item)
            }
            // If candidate is nil here, the observer task above already called
            // cancelAutoPlay() and exited cleanly, so we just fall through.
        }
    }

    private func cancelAutoPlay() {
        countdownTask?.cancel()
        candidateTask?.cancel()
        countdownTask     = nil
        candidateTask     = nil
        autoPlayCountdown = nil
        nextCandidate     = nil
    }

    // MARK: - Helpers

    private func togglePlayPause() {
        if controller.state == .playing { controller.pause() }
        else { controller.play() }
    }

    private func seekBy(_ seconds: Double) {
        guard controller.duration > 0 else { return }
        let newTime     = max(0, min(controller.duration, controller.currentTime + seconds))
        let newFraction = newTime / controller.duration
        Task { await controller.seek(toFraction: newFraction) }
    }

    private var statusColor: Color {
        switch controller.state {
        case .playing:   return .green
        case .buffering: return .orange
        case .paused:    return .yellow
        case .failed:    return .red
        case .loading:   return .orange
        default:         return .white
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
