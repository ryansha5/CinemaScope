// MARK: - Features / Player / PlayerLabHostView
// Sprint 42 — Production PlayerLab wrapper for HomeView.
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
//   • Provides a minimal transport bar (exit, seek ±30s, play/pause, progress).
//   • Does NOT contain any debug logging UI — that lives in PlayerLabPlayerView.
//
// NOT production-ready — used progressively as confidence grows across sprints.

import SwiftUI

struct PlayerLabHostView: View {

    // MARK: - Inputs

    let url:         URL
    let startTicks:  Int64
    let itemName:    String
    let backdropURL: URL?
    let onExit:      () -> Void
    let onFallback:  (String) -> Void

    // MARK: - State

    @StateObject private var controller = PlayerLabPlaybackController()

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

            // ── Transport ────────────────────────────────────────────────────
            VStack(spacing: 0) {
                Spacer()
                transportBar
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .task {
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
    }

    // MARK: - Derived

    /// Show video only once the first frame has been decoded; hides the
    /// black flash that can appear between prepare() and the first rendered frame.
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
