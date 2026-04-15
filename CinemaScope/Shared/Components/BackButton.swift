import SwiftUI

// MARK: - BackButton
// Shared focusable back button used across DetailView,
// CollectionDetailView, SettingsView, and anywhere else a back action is needed.

struct BackButton: View {
    let colorMode: ColorMode
    let scopeMode: Bool
    let onTap:     () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: scopeMode ? 14 : 17, weight: .semibold))
                Text("Back")
                    .font(.system(size: scopeMode ? 15 : 18, weight: .medium))
            }
            .foregroundStyle(isFocused ? CinemaTheme.primary(colorMode) : CinemaTheme.secondary(colorMode))
            .padding(.horizontal, scopeMode ? 18 : 24)
            .padding(.vertical,   scopeMode ? 11 : 14)
            .background(
                isFocused
                    ? CinemaTheme.peacock.opacity(0.55)
                    : CinemaTheme.surfaceNav(colorMode),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isFocused
                            ? CinemaTheme.peacockLight.opacity(0.6)
                            : CinemaTheme.border(colorMode),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            }
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(color: isFocused ? CinemaTheme.focusAccent(colorMode).opacity(0.4) : .clear, radius: 12)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}
