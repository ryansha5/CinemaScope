import SwiftUI

enum CinemaTheme {

    // MARK: - Colors
    static let peacock      = Color(red: 0.016, green: 0.376, blue: 0.416)
    static let peacockDeep  = Color(red: 0.008, green: 0.196, blue: 0.235)
    static let peacockLight = Color(red: 0.063, green: 0.541, blue: 0.565)
    static let accent       = Color(red: 0.110, green: 0.706, blue: 0.706)
    static let accentGold   = Color(red: 0.898, green: 0.749, blue: 0.400)

    // MARK: - Background Gradients
    static var backgroundGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: peacockDeep,               location: 0.0),
                .init(color: peacock.opacity(0.85),     location: 0.35),
                .init(color: peacock.opacity(0.70),     location: 0.65),
                .init(color: peacockDeep.opacity(0.95), location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var radialOverlay: RadialGradient {
        RadialGradient(
            colors: [peacockLight.opacity(0.18), .clear],
            center: .center,
            startRadius: 100,
            endRadius: 600
        )
    }

    static var cardGradient: LinearGradient {
        LinearGradient(
            colors: [peacockLight.opacity(0.15), peacockDeep.opacity(0.4)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var bottomFade: LinearGradient {
        LinearGradient(
            colors: [.clear, peacockDeep.opacity(0.6), peacockDeep],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Typography
    static let titleFont   = Font.system(size: 48, weight: .bold)
    static let sectionFont = Font.system(size: 26, weight: .semibold)
    static let bodyFont    = Font.system(size: 20, weight: .regular)
    static let captionFont = Font.system(size: 16, weight: .medium)

    // MARK: - Spacing
    static let pagePadding:    CGFloat = 80
    static let rowSpacing:     CGFloat = 56
    static let cardSpacing:    CGFloat = 28
    static let sectionSpacing: CGFloat = 20

    // MARK: - Scope UI
    static let scopeRatio:        Double  = 2.39
    static let navRailWidth:       CGFloat = 220
    static let scopeCardWidth:     CGFloat = 140   // smaller cards for scope layout
    static let scopeCardHeight:    CGFloat = 210
    static let standardCardWidth:  CGFloat = 200
    static let standardCardHeight: CGFloat = 300
}

// MARK: - CinemaBackground

struct CinemaBackground: View {
    var body: some View {
        ZStack {
            CinemaTheme.backgroundGradient.ignoresSafeArea()
            CinemaTheme.radialOverlay.ignoresSafeArea()
        }
    }
}

// MARK: - ScopeCanvasBackground
// Used in scope UI mode — true black bars above and below the canvas,
// peacock gradient only within the 2.39:1 safe zone.

struct ScopeCanvasBackground: View {
    var body: some View {
        GeometryReader { geo in
            let screen     = geo.size
            let canvas     = scopeCanvasRect(in: screen)

            ZStack(alignment: .topLeading) {
                // True black fills the entire screen
                Color.black.ignoresSafeArea()

                // Peacock gradient only inside the scope canvas
                ZStack {
                    CinemaTheme.backgroundGradient
                    CinemaTheme.radialOverlay
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
