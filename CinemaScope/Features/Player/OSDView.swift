import SwiftUI

// MARK: - OSDView
//
// Floating playback controls overlay.
// No panel background — a gradient vignette anchors the controls to the bottom
// of the viewport so they read clearly over any content without feeling harsh.
// All interactive rows are wrapped in .focusSection() so the tvOS focus engine
// can reach every button.

struct OSDView: View {

    let title:               String
    let bucket:              AspectBucket
    let mode:                PresentationMode
    let playbackState:       PlaybackState
    let currentTime:         Double
    let duration:            Double
    let aspectRatioOverride: AspectRatioOverride
    let scopeUIEnabled:      Bool
    let onModeChange:        (PresentationMode) -> Void
    let onAspectRatioChange: (AspectRatioOverride) -> Void
    let onPlayPause:         () -> Void
    let onSeek:              (Double) -> Void
    let onDismiss:           () -> Void
    let onExit:              () -> Void
    var onARMenuStateChange: ((Bool) -> Void)? = nil

    @State  private var showARMenu  = false
    @FocusState private var arMenuFocus: String?

    var body: some View {
        GeometryReader { geo in
            let vp = viewportRect(in: geo.size)

            ZStack(alignment: .bottom) {
                // AR popup floats above the control strip
                if showARMenu {
                    arMenuCard
                        .padding(.trailing, 80)
                        .padding(.bottom, controlStripHeight + 16)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }

                osdPanel
            }
            .frame(width: vp.width, height: vp.height)
            .offset(x: vp.minX, y: vp.minY)
        }
        .ignoresSafeArea()
        .onChange(of: showARMenu) { _, v in onARMenuStateChange?(v) }
    }

    // Height of the visible control strip — used to position the AR popup.
    private var controlStripHeight: CGFloat { 220 }

    // MARK: - Viewport rect

    private func viewportRect(in size: CGSize) -> CGRect {
        scopeUIEnabled
            ? ScopeCanvasGeometry.canvasRect(in: size)
            : CGRect(origin: .zero, size: size)
    }

    // MARK: - OSD panel (gradient vignette + floating controls)

    private var osdPanel: some View {
        VStack(spacing: 0) {
            // Gradient vignette — fades from clear at top to dark at bottom
            // so controls are legible without a harsh panel edge.
            LinearGradient(
                stops: [
                    .init(color: .clear,                   location: 0.00),
                    .init(color: .black.opacity(0.45),     location: 0.45),
                    .init(color: .black.opacity(0.78),     location: 1.00),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 120)

            // Control strip — sits at the bottom, no background of its own
            VStack(spacing: 20) {
                // Row A — title + badges (left) · exit (right)
                HStack(alignment: .center) {
                    metadataBlock
                    Spacer()
                    exitButton
                }
                .focusSection()

                // Row B — scrubber
                scrubberRow

                // Row C — play/pause · viewport toggle · AR trigger
                HStack(spacing: 0) {
                    playPauseButton
                    Spacer()
                    modeToggle
                    Spacer()
                    arTriggerButton
                }
                .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 52)
            .background(.black.opacity(0.78))
        }
        .focusSection()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Metadata

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)
            HStack(spacing: 8) {
                badge(bucket.label)
                badge(mode.label, accent: .blue.opacity(0.7))
                if let lbl = aspectRatioOverride.badgeLabel {
                    badge(lbl, accent: CinemaTheme.accentGold.opacity(0.6))
                }
            }
        }
    }

    private func badge(_ text: String, accent: Color = .white.opacity(0.18)) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.80))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(accent, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Scrubber

    private var scrubberRow: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: 4)
                    // Fill
                    Capsule()
                        .fill(.white.opacity(0.90))
                        .frame(width: geo.size.width * progress, height: 4)
                    // Thumb
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                        .offset(x: geo.size.width * progress - 7)
                }
            }
            .frame(height: 14)

            HStack {
                Text(formatTime(currentTime))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(formatTime(duration))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    // MARK: - Play / Pause

    private var playPauseButton: some View {
        OSDIconButton(
            systemName: playbackState == .playing ? "pause.fill" : "play.fill",
            accessibilityLabel: playbackState == .playing ? "Pause" : "Play",
            action: onPlayPause
        )
    }

    // MARK: - Viewport mode toggle

    private var modeToggle: some View {
        HStack(spacing: 0) {
            Text("Viewport")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .padding(.trailing, 12)

            HStack(spacing: 6) {
                ForEach(PresentationMode.allCases.filter(\.isImplemented)) { m in
                    OSDPillButton(
                        label:       m.label,
                        isActive:    mode == m,
                        accentColor: .blue
                    ) { onModeChange(m) }
                }
            }
            .focusSection()
        }
    }

    // MARK: - Aspect ratio trigger

    private var arTriggerButton: some View {
        ARTriggerButton(
            currentOverride: aspectRatioOverride,
            isMenuOpen: showARMenu
        ) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                showARMenu.toggle()
            }
            if showARMenu {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    arMenuFocus = aspectRatioOverride.rawValue
                }
            }
        }
    }

    // MARK: - AR menu card

    private var arMenuCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Text("Aspect Ratio")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.60))
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)

            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
                .padding(.horizontal, 14)

            VStack(spacing: 0) {
                ForEach(AspectRatioOverride.allCases) { ar in
                    ARMenuRow(
                        ar: ar,
                        isSelected: aspectRatioOverride == ar,
                        externalFocus: $arMenuFocus
                    ) {
                        onAspectRatioChange(ar)
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            showARMenu = false
                        }
                    }
                }
            }
            .focusSection()
            .padding(.bottom, 10)
        }
        .frame(width: 300)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.black.opacity(0.78))
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.07), location: 0),
                        .init(color: .clear,               location: 0.4),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
    }

    // MARK: - Exit

    private var exitButton: some View {
        OSDExitButton(action: onExit)
    }

    // MARK: - Helpers

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let t = Int(seconds)
        let h = t / 3600; let m = (t % 3600) / 60; let s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - OSDIconButton
//
// Borderless icon button (play/pause). Glows on focus; no ring, no box.

private struct OSDIconButton: View {
    let systemName:         String
    let accessibilityLabel: String
    let action:             () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white.opacity(isFocused ? 1.0 : 0.75))
                .frame(width: 60, height: 60)
                .background {
                    Circle()
                        .fill(.white.opacity(isFocused ? 0.20 : 0.08))
                }
                .scaleEffect(isFocused ? 1.12 : 1.0)
                .shadow(color: .white.opacity(isFocused ? 0.30 : 0), radius: 16)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - OSDExitButton
//
// "← Library" text button. No background when resting; subtle highlight on focus.

private struct OSDExitButton: View {
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                Text("Library")
                    .font(.system(size: 18, weight: .medium))
            }
            .foregroundStyle(.white.opacity(isFocused ? 1.0 : 0.55))
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 22)
                    .fill(.white.opacity(isFocused ? 0.16 : 0.0))
            }
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - OSDPillButton
//
// Glass pill for the viewport mode toggle (Scope Safe / Full Screen).

private struct OSDPillButton: View {
    let label:       String
    let isActive:    Bool
    let accentColor: Color
    let action:      () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(
                    isActive
                        ? (isFocused ? Color.black : Color.black)
                        : (isFocused ? Color.white : Color.white.opacity(0.60))
                )
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isActive
                              ? accentColor.opacity(isFocused ? 1.0 : 0.80)
                              : .white.opacity(isFocused ? 0.22 : 0.08))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(
                            isActive
                                ? Color.clear
                                : Color.white.opacity(isFocused ? 0.40 : 0.18),
                            lineWidth: 1
                        )
                }
                .scaleEffect(isFocused ? 1.06 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - ARTriggerButton

private struct ARTriggerButton: View {
    let currentOverride: AspectRatioOverride
    let isMenuOpen:      Bool
    let action:          () -> Void

    @FocusState private var isFocused: Bool

    private var label: String {
        currentOverride == .auto ? "Aspect Ratio" : currentOverride.label
    }
    private var highlighted: Bool { isFocused || isMenuOpen }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                Image(systemName: isMenuOpen ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(highlighted ? Color.black : Color.white.opacity(0.65))
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 20)
                    .fill(isMenuOpen
                          ? CinemaTheme.accentGold.opacity(highlighted ? 1.0 : 0.85)
                          : .white.opacity(highlighted ? 0.22 : 0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        isMenuOpen
                            ? Color.clear
                            : Color.white.opacity(highlighted ? 0.40 : 0.18),
                        lineWidth: 1
                    )
            }
            .scaleEffect(highlighted ? 1.06 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isFocused)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isMenuOpen)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - ARMenuRow

private struct ARMenuRow: View {
    let ar:            AspectRatioOverride
    let isSelected:    Bool
    var externalFocus: FocusState<String?>.Binding
    let onSelect:      () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isSelected ? CinemaTheme.accentGold : .white.opacity(0.28),
                            lineWidth: 1.5
                        )
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Circle()
                            .fill(CinemaTheme.accentGold)
                            .frame(width: 9, height: 9)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(ar.label)
                        .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.white)
                    if let ratio = ar.fixedRatio {
                        Text(String(format: "%.2f : 1", ratio))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.38))
                    } else {
                        Text("Detected automatically")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.38))
                    }
                }

                Spacer()

                if isFocused {
                    Image(systemName: "return")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.40))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background {
                if isFocused {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.white.opacity(0.12))
                        .padding(.horizontal, 5)
                }
            }
            .contentShape(Rectangle())
        }
        .focusRingFree()
        .focused($isFocused)
        .focused(externalFocus, equals: ar.rawValue)
        .onChange(of: isFocused) { _, focused in
            if focused { externalFocus.wrappedValue = ar.rawValue }
        }
    }
}
