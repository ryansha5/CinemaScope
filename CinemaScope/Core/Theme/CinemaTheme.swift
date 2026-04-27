import SwiftUI

// MARK: - ColorMode

enum ColorMode: String, Codable, CaseIterable, Identifiable {
    case dark  = "dark"
    case light = "light"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .dark:  return "Dark Theater"
        case .light: return "Frosted Glass"
        }
    }
}

// MARK: - CinemaTheme
// All color decisions go through the active ColorMode.
// Static values (spacing, typography, layout) are mode-independent.

enum CinemaTheme {

    // ─────────────────────────────────────────────
    // MARK: Raw palette — never use these directly in views
    // ─────────────────────────────────────────────

    // Dark mode palette
    static let darkBg0     = Color(red: 0.004, green: 0.08,  blue: 0.10)
    static let darkBg1     = Color(red: 0.010, green: 0.22,  blue: 0.26)
    static let darkBg2     = Color(red: 0.020, green: 0.38,  blue: 0.44)
    static let darkBg3     = Color(red: 0.016, green: 0.30,  blue: 0.36)
    static let darkBg4     = Color(red: 0.004, green: 0.10,  blue: 0.13)

    // Super Blue — primary brand blue, focus accents, CTA buttons (#1D6BFF)
    static let superBlue    = Color(red: 0.114, green: 0.420, blue: 1.000)

    // Peacock accent (shared)
    static let peacock      = Color(red: 0.016, green: 0.376, blue: 0.416)
    static let peacockDeep  = Color(red: 0.008, green: 0.196, blue: 0.235)
    static let peacockLight = Color(red: 0.063, green: 0.541, blue: 0.565)
    static let teal         = Color(red: 0.110, green: 0.706, blue: 0.706)

    // Gold (dark mode accent only)
    static let gold         = Color(red: 0.898, green: 0.749, blue: 0.400)

    // Light mode palette
    static let frostBase    = Color(red: 0.94,  green: 0.96,  blue: 0.97)
    static let frostMid     = Color(red: 0.88,  green: 0.93,  blue: 0.95)
    static let frostDeep    = Color(red: 0.78,  green: 0.87,  blue: 0.91)
    static let frostText    = Color(red: 0.08,  green: 0.14,  blue: 0.18)
    static let frostSubtext = Color(red: 0.25,  green: 0.38,  blue: 0.44)

    // ─────────────────────────────────────────────
    // MARK: Semantic tokens — use these in all views
    // ─────────────────────────────────────────────

    static func bg(_ mode: ColorMode) -> Color {
        mode == .dark ? darkBg0 : frostBase
    }

    static func surface(_ mode: ColorMode) -> Color {
        mode == .dark ? peacockDeep.opacity(0.5) : Color.white.opacity(0.7)
    }

    static func surfaceRaised(_ mode: ColorMode) -> Color {
        mode == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.85)
    }

    static func textPrimary(_ mode: ColorMode) -> Color {
        mode == .dark ? .white : frostText
    }

    static func textSecondary(_ mode: ColorMode) -> Color {
        mode == .dark ? .white.opacity(0.6) : frostSubtext
    }

    static func textTertiary(_ mode: ColorMode) -> Color {
        mode == .dark ? .white.opacity(0.35) : frostSubtext.opacity(0.6)
    }

    static func accent(_ mode: ColorMode) -> Color {
        mode == .dark ? gold : peacock
    }

    static func accentAlt(_ mode: ColorMode) -> Color {
        mode == .dark ? teal : teal
    }

    static func focusRim(_ mode: ColorMode) -> LinearGradient {
        mode == .dark
            // Iridescent peacock: bright teal → luminous peacock-light (feather shimmer)
            ? LinearGradient(colors: [teal, peacockLight], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [peacock, peacockLight], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func focusShadowColor(_ mode: ColorMode) -> Color {
        // Dark: teal glow replaces gold — peacock-feather hover signature
        mode == .dark ? teal.opacity(0.65) : peacock.opacity(0.45)
    }

    static func focusShadowAlt(_ mode: ColorMode) -> Color {
        mode == .dark ? peacockLight.opacity(0.40) : peacockLight.opacity(0.3)
    }

    // Full alias set matching HomeView's token API
    static func primary(_ mode: ColorMode)    -> Color { textPrimary(mode) }
    static func secondary(_ mode: ColorMode)  -> Color { textSecondary(mode) }
    static func tertiary(_ mode: ColorMode)   -> Color { textTertiary(mode) }
    static func navActive(_ mode: ColorMode)  -> Color { accent(mode) }
    static func border(_ mode: ColorMode)     -> Color { navBorder(mode) }
    static func surfaceNav(_ mode: ColorMode) -> Color { surface(mode) }

    // Focus aliases
    static func focusRimGradient(_ mode: ColorMode) -> LinearGradient { focusRim(mode) }
    static func focusAccent(_ mode: ColorMode)      -> Color { focusShadowColor(mode) }
    static func focusGlow(_ mode: ColorMode)        -> Color { focusShadowAlt(mode) }

    static func navBackground(_ mode: ColorMode) -> Color {
        mode == .dark
            ? Color(red: 0.004, green: 0.08, blue: 0.10).opacity(0.85)
            : frostBase.opacity(0.92)
    }

    static func navBorder(_ mode: ColorMode) -> Color {
        mode == .dark ? peacockLight.opacity(0.15) : peacock.opacity(0.15)
    }

    static func cardPlaceholder(_ mode: ColorMode) -> LinearGradient {
        mode == .dark
            ? cardGradient(.dark)
            : LinearGradient(colors: [frostMid, frostDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // ─────────────────────────────────────────────
    // MARK: Background Gradients
    // ─────────────────────────────────────────────

    // Mode-parameterised gradient functions — called as CinemaTheme.backgroundGradient(.dark)
    static func backgroundGradient(_ mode: ColorMode) -> LinearGradient {
        mode == .dark
        ? LinearGradient(
            stops: [
                .init(color: darkBg0, location: 0.0),
                .init(color: darkBg1, location: 0.2),
                .init(color: darkBg2, location: 0.45),
                .init(color: darkBg3, location: 0.7),
                .init(color: darkBg4, location: 1.0),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        : LinearGradient(
            stops: [
                .init(color: frostBase,                                  location: 0.0),
                .init(color: frostMid,                                   location: 0.3),
                .init(color: Color(red: 0.84, green: 0.92, blue: 0.95), location: 0.55),
                .init(color: frostMid,                                   location: 0.75),
                .init(color: frostBase,                                  location: 1.0),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func radialOverlay(_ mode: ColorMode) -> RadialGradient {
        mode == .dark
        ? RadialGradient(
            stops: [
                .init(color: Color(red: 0.08, green: 0.65, blue: 0.72).opacity(0.35), location: 0.0),
                .init(color: Color(red: 0.04, green: 0.50, blue: 0.58).opacity(0.18), location: 0.4),
                .init(color: .clear, location: 1.0),
            ],
            center: UnitPoint(x: 0.55, y: 0.42), startRadius: 0, endRadius: 750)
        : RadialGradient(
            stops: [
                .init(color: peacock.opacity(0.22),      location: 0.0),
                .init(color: peacockLight.opacity(0.10), location: 0.45),
                .init(color: .clear,                     location: 1.0),
            ],
            center: UnitPoint(x: 0.5, y: 0.4), startRadius: 0, endRadius: 800)
    }

    static func shimmerOverlay(_ mode: ColorMode) -> LinearGradient {
        mode == .dark
        ? LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0.00), location: 0.0),
                .init(color: Color.white.opacity(0.04), location: 0.5),
                .init(color: Color.white.opacity(0.00), location: 1.0),
            ],
            startPoint: UnitPoint(x: 0.0, y: 0.0), endPoint: UnitPoint(x: 1.0, y: 1.0))
        : LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0.00), location: 0.0),
                .init(color: Color.white.opacity(0.40), location: 0.45),
                .init(color: Color.white.opacity(0.20), location: 0.55),
                .init(color: Color.white.opacity(0.00), location: 1.0),
            ],
            startPoint: UnitPoint(x: 0.0, y: 0.0), endPoint: UnitPoint(x: 1.0, y: 1.0))
    }

    static func cardGradient(_ mode: ColorMode = .dark) -> LinearGradient {
        mode == .dark
        ? LinearGradient(
            colors: [peacockLight.opacity(0.15), peacockDeep.opacity(0.4)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        : LinearGradient(
            colors: [frostMid, frostDeep],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var bottomFade: LinearGradient {
        LinearGradient(
            colors: [.clear, peacockDeep.opacity(0.6), peacockDeep],
            startPoint: .top, endPoint: .bottom
        )
    }

    // ─────────────────────────────────────────────
    // MARK: Typography (mode-independent)
    // ─────────────────────────────────────────────

    static let titleFont   = Font.system(size: 48, weight: .bold)
    static let sectionFont = Font.system(size: 26, weight: .semibold)
    static let bodyFont    = Font.system(size: 20, weight: .regular)
    static let captionFont = Font.system(size: 16, weight: .medium)

    // ─────────────────────────────────────────────
    // MARK: Spacing (mode-independent)
    // ─────────────────────────────────────────────

    static let pagePadding:    CGFloat = 24
    static let rowSpacing:     CGFloat = 56
    static let cardSpacing:    CGFloat = 28
    static let sectionSpacing: CGFloat = 20

    // ─────────────────────────────────────────────
    // MARK: Layout (mode-independent)
    // ─────────────────────────────────────────────

    static let scopeRatio:         Double  = 2.39
    static let navRailWidth:         CGFloat = 240
    static let navRailCollapsedWidth: CGFloat = 68    // icon-only collapsed state
    static let scopeCardWidth:      CGFloat = 140
    static let scopeCardHeight:     CGFloat = 210
    static let standardCardWidth:   CGFloat = 200
    static let standardCardHeight:  CGFloat = 300
    // legacy alias — accentGold kept for any files that still reference it
    static let accentGold = gold
}

// ─────────────────────────────────────────────
// MARK: - Background Views
// ─────────────────────────────────────────────

/// Full-screen background — reads current color mode from environment
struct CinemaBackground: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ZStack {
            CinemaTheme.backgroundGradient(settings.colorMode).ignoresSafeArea()
            CinemaTheme.radialOverlay(settings.colorMode).ignoresSafeArea()
            CinemaTheme.shimmerOverlay(settings.colorMode).ignoresSafeArea()
        }
    }
}

/// Scope mode background — always true black bars, theme applies only inside canvas
struct ScopeCanvasBackground: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        GeometryReader { geo in
            let canvas = scopeCanvasRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                // ALWAYS true black — blends with projector masking regardless of color mode
                Color.black.ignoresSafeArea()

                // Theme gradient inside canvas only — bars always black
                ZStack {
                    CinemaTheme.backgroundGradient(settings.colorMode)
                    CinemaTheme.radialOverlay(settings.colorMode)
                    CinemaTheme.shimmerOverlay(settings.colorMode)
                }
                .frame(width: canvas.width, height: canvas.height)
                .offset(x: canvas.minX, y: canvas.minY)
            }
        }
        .ignoresSafeArea()
    }

    private func scopeCanvasRect(in size: CGSize) -> CGRect {
        let h = size.width / CinemaTheme.scopeRatio
        let y = (size.height - h) / 2
        return CGRect(x: 0, y: y, width: size.width, height: h)
    }
}
