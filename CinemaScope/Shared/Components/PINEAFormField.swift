import SwiftUI

// MARK: - PINEAFormField
//
// Branded text / secure field used across WelcomeView, LoginView,
// RegisterView, and ServerSetupView.

struct PINEAFormField<F: Hashable>: View {

    let label:       String
    let placeholder: String
    @Binding var text: String
    var isSecure:   Bool = false
    var isFocused:  Bool = false
    var icon:       String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Label
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CinemaTheme.gold.opacity(0.75))
                .padding(.leading, 4)

            // Input row
            HStack(spacing: 14) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(isFocused
                            ? CinemaTheme.gold.opacity(0.8)
                            : Color.white.opacity(0.3))
                        .frame(width: 24)
                        .animation(.easeOut(duration: 0.15), value: isFocused)
                }

                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white.opacity(isFocused ? 0.11 : 0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                isFocused
                                    ? LinearGradient(
                                        colors: [CinemaTheme.gold.opacity(0.7), CinemaTheme.peacockLight.opacity(0.5)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
                                    : LinearGradient(
                                        colors: [Color.white.opacity(0.18), Color.white.opacity(0.08)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: isFocused ? 1.5 : 1.0
                            )
                    }
            }
            .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}
