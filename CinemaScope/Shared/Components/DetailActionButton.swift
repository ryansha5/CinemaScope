import SwiftUI

// MARK: - DetailActionButton
//
// Primary/secondary/tertiary CTA button used on the Detail screen.
// Extracted from DetailView — no logic changes.

struct DetailActionButton: View {
    enum Style { case primary, secondary, tertiary }
    let icon:      String
    let label:     String
    let style:     Style
    let scopeMode: Bool
    let isFocused: Bool
    let colorMode: ColorMode
    let action:    () -> Void

    private var radius: CGFloat { 10 }

    // Base tint color per style
    private var tintColor: Color {
        switch style {
        case .primary:  return .white
        case .secondary: return CinemaTheme.peacock
        case .tertiary:  return CinemaTheme.peacockDeep
        }
    }

    // Outer glow color on focus
    // Dark mode: all buttons glow in peacock-feather teal
    // Light mode: primary keeps peacock, secondary/tertiary same
    private var glowColor: Color {
        switch style {
        case .primary:   return colorMode == .dark ? CinemaTheme.teal : CinemaTheme.peacock
        case .secondary: return CinemaTheme.teal
        case .tertiary:  return CinemaTheme.peacockLight
        }
    }

    // Base opacity — primary is brighter glass so it reads as the dominant CTA
    private var baseOpacity: Double {
        switch style {
        case .primary:  return isFocused ? 0.52 : 0.38
        case .secondary: return isFocused ? 0.28 : 0.14
        case .tertiary:  return isFocused ? 0.20 : 0.10
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: scopeMode ? 16 : 20, weight: .semibold))
                Text(label)
                    .font(.system(size: scopeMode ? 17 : 21, weight: .semibold))
            }
            // Primary keeps black text (bright glass base = enough contrast)
            // Secondary/tertiary use white on dark glass
            .foregroundStyle(style == .primary ? Color.black : Color.white)
            .padding(.horizontal, scopeMode ? 22 : 32)
            .padding(.vertical,   scopeMode ? 13 : 17)
            .background { glassBackground }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay { glassBorder }
            .scaleEffect(isFocused ? 1.06 : 1.0)
            // Wide color glow — the "light shining" signature
            .shadow(color: glowColor.opacity(isFocused ? 0.70 : 0), radius: 30, x: 0, y: 0)
            // Tight white upward shine — simulates reflected light above the button
            .shadow(color: Color.white.opacity(isFocused ? 0.22 : 0), radius: 8, x: 0, y: -5)
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: isFocused)
        }
        .focusRingFree()
    }

    // Three-layer glass fill: base tint + top specular + bottom edge reflection
    @ViewBuilder
    private var glassBackground: some View {
        ZStack {
            // 1. Base tint
            tintColor.opacity(baseOpacity)

            // 2. Top specular — overhead light hitting the top rim of the glass
            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(isFocused ? 0.60 : 0.30), location: 0.00),
                    .init(color: Color.white.opacity(isFocused ? 0.20 : 0.08), location: 0.42),
                    .init(color: Color.clear,                                   location: 0.72),
                ],
                startPoint: .top,
                endPoint:   .bottom
            )

            // 3. Bottom edge bounce — subtle second reflection at the base
            LinearGradient(
                stops: [
                    .init(color: Color.clear,                                    location: 0.65),
                    .init(color: Color.white.opacity(isFocused ? 0.14 : 0.05),  location: 1.00),
                ],
                startPoint: .top,
                endPoint:   .bottom
            )
        }
    }

    // Gradient stroke: bright at top-left (light source), dim at bottom-right (shadow)
    @ViewBuilder
    private var glassBorder: some View {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(isFocused ? 0.90 : 0.45), location: 0.00),
                        .init(color: Color.white.opacity(isFocused ? 0.45 : 0.20), location: 0.50),
                        .init(color: Color.white.opacity(isFocused ? 0.18 : 0.08), location: 1.00),
                    ],
                    startPoint: .topLeading,
                    endPoint:   .bottomTrailing
                ),
                lineWidth: isFocused ? 1.5 : 1.0
            )
    }
}
