import SwiftUI

// MARK: - NavTab

enum NavTab: String, CaseIterable, Identifiable {
    case home        = "Home"
    case movies      = "Movies"
    case tvShows     = "TV Shows"
    case collections = "Collections"
    case playlists   = "Playlists"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home:        return "house.fill"
        case .movies:      return "film"
        case .tvShows:     return "tv"
        case .collections: return "rectangle.stack"
        case .playlists:   return "music.note.list"
        }
    }
}

// MARK: - NavTabButton

struct NavTabButton: View {

    let tab:      NavTab
    let isActive: Bool
    let compact:  Bool
    let onTap:    () -> Void

    @EnvironmentObject var settings: AppSettings
    @FocusState private var isFocused: Bool

    var body: some View {
        let mode = settings.colorMode
        Button { onTap() } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: compact ? 15 : 16,
                                  weight: isActive ? .semibold : .regular))
                Text(tab.rawValue)
                    .font(.system(size: compact ? 16 : 18,
                                  weight: isActive ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
                if compact { Spacer() }
            }
            .foregroundStyle(
                isActive  ? CinemaTheme.navActive(mode) :
                isFocused ? CinemaTheme.primary(mode)   :
                            CinemaTheme.secondary(mode)
            )
            .scaleEffect(isFocused ? 1.04 : 1.0, anchor: .leading)
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical,   compact ? 10 : 12)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .background {
                ZStack {
                    // Base tint
                    (isActive ? CinemaTheme.navActive(mode) : Color.white)
                        .opacity(
                            isActive && isFocused ? 0.22 :
                            isActive              ? 0.13 :
                            isFocused             ? 0.13 : 0
                        )
                    // Top specular sheen
                    if isActive || isFocused {
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(isFocused ? 0.42 : 0.18), location: 0.00),
                                .init(color: .white.opacity(isFocused ? 0.10 : 0.04), location: 0.45),
                                .init(color: .clear,                                   location: 0.72),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(isActive || isFocused ? (isFocused ? 0.70 : 0.38) : 0), location: 0.00),
                                .init(color: .white.opacity(isActive || isFocused ? (isFocused ? 0.28 : 0.14) : 0), location: 0.50),
                                .init(color: .white.opacity(isActive || isFocused ? (isFocused ? 0.10 : 0.05) : 0), location: 1.00),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: (isActive || isFocused) ? 1.5 : 0
                    )
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - ScopeToggleButton

struct ScopeToggleButton: View {
    @Binding var enabled: Bool
    let compact: Bool
    @EnvironmentObject var settings: AppSettings
    @FocusState private var isFocused: Bool

    var body: some View {
        let mode = settings.colorMode
        Button { enabled.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: enabled ? "rectangle.inset.filled" : "rectangle")
                    .font(.system(size: compact ? 15 : 17, weight: .medium))
                Text("Scope UI")
                    .font(.system(size: compact ? 16 : 17, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
                if compact { Spacer() }
            }
            .foregroundStyle(
                enabled   ? CinemaTheme.navActive(mode) :
                isFocused ? CinemaTheme.primary(mode)   :
                            CinemaTheme.secondary(mode)
            )
            .scaleEffect(isFocused ? 1.04 : 1.0, anchor: .leading)
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical,   compact ? 10 : 12)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .background {
                ZStack {
                    (enabled ? CinemaTheme.navActive(mode) : Color.white)
                        .opacity(
                            enabled && isFocused ? 0.22 :
                            enabled              ? 0.13 :
                            isFocused            ? 0.13 : 0
                        )
                    if enabled || isFocused {
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(isFocused ? 0.42 : 0.18), location: 0.00),
                                .init(color: .white.opacity(isFocused ? 0.10 : 0.04), location: 0.45),
                                .init(color: .clear,                                   location: 0.72),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(enabled || isFocused ? (isFocused ? 0.70 : 0.38) : 0), location: 0.00),
                                .init(color: .white.opacity(enabled || isFocused ? (isFocused ? 0.28 : 0.14) : 0), location: 0.50),
                                .init(color: .white.opacity(enabled || isFocused ? (isFocused ? 0.10 : 0.05) : 0), location: 1.00),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: (enabled || isFocused) ? 1.5 : 0
                    )
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}

// MARK: - NavActionButton

struct NavActionButton: View {
    let icon:    String
    let label:   String
    let compact: Bool
    let action:  () -> Void
    @EnvironmentObject var settings: AppSettings
    @FocusState private var isFocused: Bool

    var body: some View {
        let mode = settings.colorMode
        Button { action() } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 15 : 18, weight: .medium))
                Text(label)
                    .font(.system(size: compact ? 16 : 18, weight: .medium))
                    .lineLimit(1)
                if compact { Spacer() }
            }
            .foregroundStyle(isFocused ? CinemaTheme.primary(mode) : CinemaTheme.secondary(mode))
            .scaleEffect(isFocused ? 1.04 : 1.0, anchor: .leading)
            .padding(.horizontal, compact ? 14 : 20)
            .padding(.vertical,   compact ? 10 : 12)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .background {
                ZStack {
                    Color.white.opacity(isFocused ? 0.16 : 0.07)
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(isFocused ? 0.44 : 0.18), location: 0.00),
                            .init(color: .white.opacity(isFocused ? 0.10 : 0.04), location: 0.45),
                            .init(color: .clear,                                   location: 0.72),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(isFocused ? 0.68 : 0.28), location: 0.00),
                                .init(color: .white.opacity(isFocused ? 0.26 : 0.12), location: 0.50),
                                .init(color: .white.opacity(isFocused ? 0.09 : 0.04), location: 1.00),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: isFocused ? 1.5 : 1.0
                    )
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }
}
