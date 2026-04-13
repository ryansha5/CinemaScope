import SwiftUI

struct OSDView: View {

    let title:        String
    let bucket:       AspectBucket
    let mode:         PresentationMode
    let playbackState: PlaybackState
    let currentTime:  Double
    let duration:     Double
    let onModeChange: (PresentationMode) -> Void
    let onPlayPause:  () -> Void
    let onSeek:       (Double) -> Void
    let onDismiss:    () -> Void
    let onExit:       () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            osdPanel
        }
        .ignoresSafeArea()
    }

    // MARK: - Panel

    private var osdPanel: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)

            VStack(spacing: 28) {
                // Row 1: title + metadata
                HStack(alignment: .center) {
                    metadataBlock
                    Spacer()
                    exitButton
                }

                // Row 2: scrubber
                scrubberRow

                // Row 3: transport + mode toggle
                HStack {
                    playPauseButton
                    Spacer()
                    modeToggle
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 36)
        }
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Metadata

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 12) {
                badge(bucket.label, color: .white.opacity(0.15))
                badge(mode.label,   color: .blue.opacity(0.4))
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Scrubber

    private var scrubberRow: some View {
        VStack(spacing: 8) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(0.2))
                        .frame(height: 6)

                    // Fill
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white)
                        .frame(width: geo.size.width * progress, height: 6)

                    // Thumb
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .offset(x: geo.size.width * progress - 9)
                }
            }
            .frame(height: 18)

            // Time labels
            HStack {
                Text(formatTime(currentTime))
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(formatTime(duration))
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Play/Pause

    private var playPauseButton: some View {
        Button(action: onPlayPause) {
            Image(systemName: playbackState == .playing ? "pause.fill" : "play.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mode Toggle

    private var modeToggle: some View {
        HStack(spacing: 16) {
            ForEach(PresentationMode.allCases.filter(\.isImplemented)) { m in
                Button {
                    onModeChange(m)
                } label: {
                    Text(m.label)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(mode == m ? .black : .white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(
                            mode == m ? Color.white : Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Exit

    private var exitButton: some View {
        Button(action: onExit) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                Text("Library")
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
