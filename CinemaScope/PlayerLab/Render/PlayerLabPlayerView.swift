// MARK: - PlayerLab / Render / PlayerLabPlayerView
//
// Sprint 10 — Frame Rendering Proof
// Sprint 11 — Timed Presentation / Playback Clock
// Sprint 13 — Audio status indicator
// Sprint 14 — Progress bar, seek ±30s, restart
// Sprint 26 — SubtitleView overlay (wired to controller.subtitleController.currentCue)
// Sprint 27 — Chapter display: current title in HUD; prev/next chapter buttons
//
// Debug-only full-screen video player view for PlayerLab.
// Presented as a fullScreenCover from PlayerLabPanel in SettingsView.
//
// NOT production UI. Debug / lab use only.

import SwiftUI
import AVFoundation

struct PlayerLabPlayerView: View {

    // MARK: - Inputs

    let url: URL

    // MARK: - State

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = PlayerLabPlaybackController()
    @State private var showLog = false

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLabDisplayView(renderer: controller.renderer)
                .ignoresSafeArea()
                .focusable(false)

            // Sprint 26: subtitle overlay — sits above video, below HUD
            SubtitleView(cue: controller.subtitleController.currentCue)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                bottomHUD
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .task {
            await controller.prepare(url: url)
            if controller.state == .ready {
                controller.play()
            }
        }
    }

    // MARK: - Bottom HUD

    @ViewBuilder
    private var bottomHUD: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Log tail (toggleable)
            if showLog && !controller.log.isEmpty {
                Text(controller.log.suffix(4).joined(separator: "\n"))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
            }

            // Sprint 27: current chapter title strip (visible when chapters are present)
            if let chapterTitle = controller.currentChapter?.title, !chapterTitle.isEmpty {
                Text(chapterTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 4)
            }

            // Progress bar + time
            if controller.duration > 0 {
                progressBar
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)
            }

            // Control bar
            HStack(spacing: 28) {

                // Dismiss
                Button(action: { dismiss() }) {
                    Label("Done", systemImage: "xmark.circle.fill")
                        .font(.system(size: 19, weight: .semibold))
                }

                // Restart
                Button(action: { Task { await controller.restart() } }) {
                    Label("Restart", systemImage: "backward.end.fill")
                        .font(.system(size: 19, weight: .semibold))
                }
                .disabled(!controller.state.canSeek && controller.state != .ended)

                // Sprint 27: previous chapter
                if !controller.chapters.isEmpty {
                    Button(action: seekPrevChapter) {
                        Label("Prev chapter", systemImage: "chevron.left.2")
                            .font(.system(size: 19, weight: .semibold))
                    }
                    .disabled(!controller.state.canSeek)
                }

                // Seek back 30s
                Button(action: { seekBy(-30) }) {
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

                // Seek forward 30s
                Button(action: { seekBy(30) }) {
                    Label("+30s", systemImage: "goforward.30")
                        .font(.system(size: 19, weight: .semibold))
                }
                .disabled(!controller.state.canSeek || controller.duration == 0)

                // Sprint 27: next chapter
                if !controller.chapters.isEmpty {
                    Button(action: seekNextChapter) {
                        Label("Next chapter", systemImage: "chevron.right.2")
                            .font(.system(size: 19, weight: .semibold))
                    }
                    .disabled(!controller.state.canSeek)
                }

                // Log toggle
                Button(action: { showLog.toggle() }) {
                    Label("Log", systemImage: showLog ? "doc.text.fill" : "doc.text")
                        .font(.system(size: 17))
                }

                Spacer()

                // Status / info panel
                VStack(alignment: .trailing, spacing: 2) {
                    Text(controller.state.statusLabel)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(statusColor)
                    if controller.framesLoaded > 0 {
                        Text("\(controller.detectedCodec)  "
                           + "\(Int(controller.firstFrameSize.width))×\(Int(controller.firstFrameSize.height))  "
                           + (controller.hasAudio ? "🔊" : "🔇"))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                        // Sprint 17: live buffer depth indicator
                        Text("buf \(String(format: "%.1f", controller.videoBuffered))s")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(bufferColor)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 18)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Progress Bar

    @ViewBuilder
    private var progressBar: some View {
        let fraction = controller.duration > 0
            ? min(1, max(0, controller.currentTime / controller.duration))
            : 0

        VStack(spacing: 4) {
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

    // Sprint 27: chapter navigation
    private func seekPrevChapter() {
        guard !controller.chapters.isEmpty else { return }
        let t         = controller.currentTime
        // Look for the last chapter that starts clearly before the current time
        // (with a 2 s tolerance so tapping "prev" at 0:02 of a chapter goes back, not stays).
        let candidate = controller.chapters.last {
            $0.startTime.seconds < t - 2.0
        }
        let target = candidate ?? controller.chapters.first!
        Task { await controller.seekToChapter(target) }
    }

    private func seekNextChapter() {
        guard !controller.chapters.isEmpty else { return }
        let t      = controller.currentTime
        let target = controller.chapters.first { $0.startTime.seconds > t }
        guard let target else { return }
        Task { await controller.seekToChapter(target) }
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

    /// Buffer depth indicator: green = healthy, yellow = low, red = critical.
    private var bufferColor: Color {
        let buf = controller.videoBuffered
        if buf > 4.0 { return .green.opacity(0.8) }
        if buf > 1.5 { return .yellow.opacity(0.8) }
        return .red.opacity(0.9)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
