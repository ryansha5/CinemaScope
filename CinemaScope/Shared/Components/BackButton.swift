import SwiftUI

// MARK: - BackButton
// Shared focusable back button used across DetailView,
// CollectionDetailView, SettingsView, and anywhere else a back action is needed.

struct BackButton: View {
    let colorMode: ColorMode
    let scopeMode: Bool
    let onTap:     () -> Void
    @FocusState private var isFocused: Bool

    private var radius: CGFloat { 10 }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: scopeMode ? 14 : 17, weight: .semibold))
                Text("Back")
                    .font(.system(size: scopeMode ? 15 : 18, weight: .medium))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, scopeMode ? 18 : 24)
            .padding(.vertical,   scopeMode ? 11 : 14)
            .background {
                ZStack {
                    Color.white.opacity(isFocused ? 0.20 : 0.10)
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(isFocused ? 0.50 : 0.22), location: 0.00),
                            .init(color: Color.white.opacity(isFocused ? 0.14 : 0.05), location: 0.45),
                            .init(color: Color.clear,                                   location: 0.72),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    LinearGradient(
                        stops: [
                            .init(color: Color.clear,                                   location: 0.65),
                            .init(color: Color.white.opacity(isFocused ? 0.10 : 0.03), location: 1.00),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(isFocused ? 0.80 : 0.35), location: 0.00),
                                .init(color: Color.white.opacity(isFocused ? 0.35 : 0.14), location: 0.50),
                                .init(color: Color.white.opacity(isFocused ? 0.14 : 0.06), location: 1.00),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: isFocused ? 1.5 : 1.0
                    )
            }
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(color: CinemaTheme.peacockLight.opacity(isFocused ? 0.60 : 0), radius: 26, x: 0, y: 0)
            .shadow(color: Color.white.opacity(isFocused ? 0.18 : 0), radius: 7, x: 0, y: -4)
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}
