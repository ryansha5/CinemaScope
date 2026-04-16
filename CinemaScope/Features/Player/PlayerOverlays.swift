import SwiftUI

// MARK: - PlayerStatusOverlay
//
// Full-screen overlay shown during loading, retrying, and playback errors.
// Extracted from PlayerContainerView (PASS 5). No logic changes.

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

    /// Error needs a dark scrim for readability.
    /// Loading/retrying stay translucent so the backdrop shows through.
    private var backgroundOpacity: Double {
        if case .error = state { return 0.82 }
        return 0.28
    }

    var body: some View {
        ZStack {
            Color.black.opacity(backgroundOpacity).ignoresSafeArea()

            VStack(spacing: 28) {
                switch state {

                case .loading(let msg):
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.6)
                        .tint(.white)
                    Text(msg)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))

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

                case .error(let msg):
                    Text("⚠️").font(.system(size: 56))
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
                    .onAppear { focusedButton = onRetry != nil ? .retry : .exit }
                }
            }
        }
    }
}

// MARK: - NextEpisodeCountdown
//
// Bottom-trailing autoplay countdown card shown when the episode is nearly over.
// Extracted from PlayerContainerView (PASS 5). No logic changes.

struct NextEpisodeCountdown: View {

    let onPlayNext: () -> Void
    let onCancel:   () -> Void

    @State private var countdown: Int = 8
    @FocusState private var focusedButton: CountdownButton?
    enum CountdownButton { case playNext, cancel }

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear

            VStack(alignment: .trailing, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(CinemaTheme.accentGold)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Next Episode")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Playing in \(countdown)s")
                                .font(.system(size: 16))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white.opacity(0.2))
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(CinemaTheme.accentGold)
                                .frame(width: geo.size.width * (1.0 - Double(countdown) / 8.0), height: 3)
                                .animation(.linear(duration: 1), value: countdown)
                        }
                    }
                    .frame(height: 3)

                    HStack(spacing: 12) {
                        CountdownActionButton(label: "Play Now",  icon: "play.fill", isPrimary: true,  isFocused: focusedButton == .playNext, action: onPlayNext)
                            .focused($focusedButton, equals: .playNext)
                        CountdownActionButton(label: "Cancel",    icon: "xmark",     isPrimary: false, isFocused: focusedButton == .cancel,   action: onCancel)
                            .focused($focusedButton, equals: .cancel)
                    }
                }
                .padding(28)
                .background {
                    ZStack {
                        Color.black.opacity(0.75)
                        LinearGradient(
                            stops: [.init(color: .white.opacity(0.08), location: 0), .init(color: .clear, location: 0.5)],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
                .frame(width: 340)
            }
            .padding(.trailing, 80)
            .padding(.bottom, 80)
        }
        .ignoresSafeArea()
        .onAppear { focusedButton = .playNext }
        .onReceive(timer) { _ in
            if countdown > 0 { countdown -= 1 }
            else             { onPlayNext() }
        }
    }
}

// MARK: - CountdownActionButton (private)

private struct CountdownActionButton: View {
    let label: String; let icon: String; let isPrimary: Bool
    let isFocused: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(label).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(isPrimary ? (isFocused ? .black : CinemaTheme.accentGold) : .white.opacity(0.7))
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background {
                ZStack {
                    (isPrimary ? CinemaTheme.accentGold : Color.white)
                        .opacity(isFocused ? (isPrimary ? 1.0 : 0.18) : (isPrimary ? 0.15 : 0.08))
                    LinearGradient(stops: [.init(color: .white.opacity(isFocused ? 0.35 : 0.12), location: 0), .init(color: .clear, location: 0.5)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(isFocused ? 0.7 : 0.3), location: 0), .init(color: .white.opacity(isFocused ? 0.2 : 0.1), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: isFocused ? 1.5 : 1) }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - OverlayActionButton (private)

private struct OverlayActionButton: View {
    let label: String; let icon: String; let isFocused: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { Image(systemName: icon); Text(label) }
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isFocused ? .black : .white)
                .padding(.horizontal, 32).padding(.vertical, 16)
                .background(isFocused ? Color.white : Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
    }
}
