// MARK: - PlayerLab / Render / PlayerLabPlayerView
//
// Sprint 10 — Frame Rendering Proof
// Sprint 11 — Timed Presentation / Playback Clock
//
// Debug-only full-screen video player view for PlayerLab.
// Presented as a fullScreenCover from PlayerLabPanel in SettingsView.
//
// Layout:
//   • Black background fills screen
//   • PlayerLabDisplayView (AVSampleBufferDisplayLayer) fills 80% of height
//   • Bottom HUD: status, play/pause button, dismiss button
//   • Log tail (last 4 lines) below HUD
//
// NOT production UI. Debug / lab use only.

import SwiftUI
import AVFoundation

struct PlayerLabPlayerView: View {

    // MARK: - Inputs

    let url:         URL
    let packetCount: Int

    // MARK: - State

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = PlayerLabPlaybackController()
    @State private var showLog = false

    // MARK: - Body

    var body: some View {
        ZStack {

            // Full-screen black background
            Color.black.ignoresSafeArea()

            // Video surface
            PlayerLabDisplayView(renderer: controller.renderer)
                .ignoresSafeArea()
                .focusable(false)   // prevent tvOS focus landing on the surface

            // Bottom overlay
            VStack(spacing: 0) {
                Spacer()
                bottomHUD
            }
            .ignoresSafeArea(edges: .bottom)
        }
        // Prepare + auto-play when the view appears
        .task {
            await controller.prepare(url: url, packetCount: packetCount)
            // Auto-play as soon as the pipeline is ready
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
                    .padding(.vertical, 10)
            }

            // Control bar
            HStack(spacing: 32) {

                // Dismiss
                Button(action: { dismiss() }) {
                    Label("Done", systemImage: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                }

                // Play / Pause
                Button(action: togglePlayPause) {
                    Label(
                        controller.state == .playing ? "Pause" : "Play",
                        systemImage: controller.state == .playing ? "pause.fill" : "play.fill"
                    )
                    .font(.system(size: 20, weight: .semibold))
                }
                .disabled(!controller.state.canPlay && !controller.state.canPause)

                // Log toggle
                Button(action: { showLog.toggle() }) {
                    Label("Log", systemImage: showLog ? "doc.text.fill" : "doc.text")
                        .font(.system(size: 18))
                }

                Spacer()

                // Status / codec / frame count
                VStack(alignment: .trailing, spacing: 2) {
                    Text(controller.state.statusLabel)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(statusColor)
                    if controller.framesLoaded > 0 {
                        Text("\(controller.framesLoaded) frames  \(controller.detectedCodec)  " +
                             "\(Int(controller.firstFrameSize.width))×\(Int(controller.firstFrameSize.height))")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 20)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Helpers

    private func togglePlayPause() {
        if controller.state == .playing {
            controller.pause()
        } else {
            controller.play()
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .playing:       return .green
        case .paused:        return .yellow
        case .failed:        return .red
        case .loading:       return .orange
        default:             return .white
        }
    }
}
