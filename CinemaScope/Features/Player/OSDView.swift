import SwiftUI

// MARK: - OSDView

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
    /// Called whenever the AR pop-up opens or closes so the UIKit container
    /// can suppress its "down arrow → hide OSD" shortcut while the menu is up.
    var onARMenuStateChange: ((Bool) -> Void)? = nil

    // AR menu state
    @State private var showARMenu = false
    /// Tracks which AR option has focus inside the popup so we can jump to the
    /// currently-selected item when the menu first opens.
    @FocusState private var arMenuFocus: String?

    var body: some View {
        GeometryReader { geo in
            let vp = viewportRect(in: geo.size)

            ZStack(alignment: .bottomLeading) {
                // ── Main layout — pinned to the bottom of the viewport ─────────
                VStack(spacing: 0) {
                    Spacer()

                    // AR popup floats directly above the panel
                    if showARMenu {
                        arMenuCard
                            .padding(.horizontal, 80)
                            .padding(.bottom, 10)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    osdPanel
                }
                // Constrain to scope canvas when in scope mode so the OSD never
                // bleeds into the letterbox bars.
                .frame(width: vp.width, height: vp.height)
                .offset(x: vp.minX, y: vp.minY)
            }
        }
        .ignoresSafeArea()
        .onChange(of: showARMenu) { _, newValue in
            onARMenuStateChange?(newValue)
        }
    }

    // MARK: - Viewport rect

    private func viewportRect(in size: CGSize) -> CGRect {
        scopeUIEnabled
            ? ScopeCanvasGeometry.canvasRect(in: size)
            : CGRect(origin: .zero, size: size)
    }

    // MARK: - Panel

    private var osdPanel: some View {
        VStack(spacing: 0) {
            // Top separator
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)

            VStack(spacing: 22) {
                // Row 1 — title + badges + exit
                HStack(alignment: .center) {
                    metadataBlock
                    Spacer()
                    exitButton
                }

                // Row 2 — scrubber
                scrubberRow

                // Row 3 — play/pause · viewport mode · aspect ratio trigger
                HStack(spacing: 0) {
                    playPauseButton
                    Spacer()
                    modeToggle
                    Spacer()
                    arTriggerButton
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 28)
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
            HStack(spacing: 10) {
                badge(bucket.label, color: .white.opacity(0.15))
                badge(mode.label,   color: .blue.opacity(0.40))
                if let overrideLabel = aspectRatioOverride.badgeLabel {
                    badge(overrideLabel, color: CinemaTheme.accentGold.opacity(0.45))
                }
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Scrubber

    private var scrubberRow: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.2)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: geo.size.width * progress, height: 6)
                    Circle().fill(.white).frame(width: 18, height: 18).offset(x: geo.size.width * progress - 9)
                }
            }
            .frame(height: 18)
            HStack {
                Text(formatTime(currentTime)).font(.system(size: 16, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(formatTime(duration)).font(.system(size: 16, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
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
                .background {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.15))
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.40), location: 0.0),
                                .init(color: .white.opacity(0.08), location: 0.5),
                                .init(color: .clear,               location: 0.8),
                            ],
                            startPoint: .top, endPoint: .bottom
                        ).clipShape(Circle())
                    }
                }
                .overlay { Circle().strokeBorder(.white.opacity(0.30), lineWidth: 1) }
        }
        .focusRingFree()
        .accessibilityLabel(playbackState == .playing ? "Pause" : "Play")
    }

    // MARK: - Viewport mode toggle (Scope Safe / Full Screen)

    private var modeToggle: some View {
        HStack(spacing: 0) {
            Text("Viewport:")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.40))
                .padding(.trailing, 12)

            HStack(spacing: 8) {
                ForEach(PresentationMode.allCases.filter(\.isImplemented)) { m in
                    OSDPillButton(
                        label: m.label,
                        isActive: mode == m,
                        accentColor: .blue
                    ) { onModeChange(m) }
                }
            }
        }
    }

    // MARK: - Aspect ratio trigger button

    private var arTriggerButton: some View {
        ARTriggerButton(
            currentOverride: aspectRatioOverride,
            isMenuOpen: showARMenu
        ) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                showARMenu.toggle()
            }
            // Give focus to the currently-selected item in the popup
            if showARMenu {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    arMenuFocus = aspectRatioOverride.rawValue
                }
            }
        }
    }

    // MARK: - AR menu card (floats above the panel)

    private var arMenuCard: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Aspect Ratio")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

                Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.horizontal, 14)

                // Options — .focusSection() keeps directional navigation
                // contained inside the card so a down-swipe can't escape
                // the menu and trigger the OSD's hide-on-down-arrow path.
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
            .frame(width: 320)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.72))
                    LinearGradient(
                        stops: [.init(color: .white.opacity(0.08), location: 0), .init(color: .clear, location: 0.4)],
                        startPoint: .top, endPoint: .bottom
                    ).clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
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
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(.white.opacity(0.10))
                    LinearGradient(
                        stops: [.init(color: .white.opacity(0.28), location: 0), .init(color: .clear, location: 0.65)],
                        startPoint: .top, endPoint: .bottom
                    ).clipShape(RoundedRectangle(cornerRadius: 24))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
        }
        .focusRingFree()
    }

    // MARK: - Helpers

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - OSDPillButton
//
// Glass pill used for the viewport mode toggle (Scope Safe / Full Screen).

private struct OSDPillButton: View {
    let label:       String
    let isActive:    Bool
    let accentColor: Color
    let action:      () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(
                    isActive
                        ? Color.black
                        : (isFocused ? Color.black : Color.white)
                )
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22)
                            .fill(isActive
                                ? accentColor.opacity(isFocused ? 1.0 : 0.85)
                                : (isFocused ? Color.white.opacity(0.28) : Color.white.opacity(0.10)))
                        if !isActive {
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(isFocused ? 0.35 : 0.18), location: 0),
                                    .init(color: .clear, location: 0.6),
                                ],
                                startPoint: .top, endPoint: .bottom
                            ).clipShape(RoundedRectangle(cornerRadius: 22))
                        }
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(.white.opacity(isActive ? 0 : (isFocused ? 0.55 : 0.22)), lineWidth: 1)
                }
                .scaleEffect(isFocused ? 1.05 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - ARTriggerButton
//
// Single pill that shows the current AR selection and opens/closes the popup menu.

private struct ARTriggerButton: View {
    let currentOverride: AspectRatioOverride
    let isMenuOpen: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    private var label: String {
        currentOverride == .auto ? "Aspect Ratio" : currentOverride.label
    }

    private var isHighlighted: Bool { isFocused || isMenuOpen }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 16, weight: .medium))
                Image(systemName: isMenuOpen ? "chevron.down" : "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isHighlighted ? Color.black : Color.white)
            .padding(.horizontal, 22).padding(.vertical, 12)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(isMenuOpen
                            ? CinemaTheme.accentGold.opacity(isHighlighted ? 1.0 : 0.88)
                            : (isHighlighted ? Color.white.opacity(0.28) : Color.white.opacity(0.10)))
                    if !isMenuOpen {
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(isHighlighted ? 0.35 : 0.18), location: 0),
                                .init(color: .clear, location: 0.6),
                            ],
                            startPoint: .top, endPoint: .bottom
                        ).clipShape(RoundedRectangle(cornerRadius: 22))
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(.white.opacity(isMenuOpen ? 0 : (isHighlighted ? 0.55 : 0.22)), lineWidth: 1)
            }
            .scaleEffect(isHighlighted ? 1.05 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isFocused)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isMenuOpen)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - ARMenuRow
//
// A single option row inside the AR popup menu.

private struct ARMenuRow: View {
    let ar:            AspectRatioOverride
    let isSelected:    Bool
    var externalFocus: FocusState<String?>.Binding
    let onSelect:      () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                // Selection indicator
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? CinemaTheme.accentGold : .white.opacity(0.30), lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    if isSelected {
                        Circle()
                            .fill(CinemaTheme.accentGold)
                            .frame(width: 10, height: 10)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(ar.label)
                        .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.white)
                    if let ratio = ar.fixedRatio {
                        Text(String(format: "%.2f : 1", ratio))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                    } else {
                        Text("Detected automatically")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }

                Spacer()

                if isFocused {
                    Image(systemName: "return")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                if isFocused {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.15))
                        .padding(.horizontal, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .focusRingFree()
        .focused($isFocused)
        .focused(externalFocus, equals: ar.rawValue)
        .onChange(of: isFocused) { _, focused in
            // Keep external binding in sync so the trigger button can read it
            if focused { externalFocus.wrappedValue = ar.rawValue }
        }
    }
}
