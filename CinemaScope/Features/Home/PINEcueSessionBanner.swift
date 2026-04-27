import SwiftUI

// MARK: - PINEcueSessionBanner
//
// Sprint 6: surface the movie selected in PINEcue on the PINEA home screen.
// Read-only — does not drive playback or bypass the normal detail/play flow.
// Tapping routes into the existing PINEA detail view via the provided closure.

struct PINEcueSessionBanner: View {

    let summary:         PINEASessionMovieSummary
    let isPlaying:       Bool          // true when backend session state is playing/buffering
    let isLoading:       Bool          // true while the EmbyItem fetch is in flight
    let scopeMode:       Bool
    let onTap:           () -> Void

    @EnvironmentObject var settings: AppSettings
    @FocusState private var isFocused: Bool

    // MARK: - Layout constants

    private var thumbWidth:  CGFloat { scopeMode ? 160 : 200 }
    private var thumbHeight: CGFloat { scopeMode ? 90  : 112 }

    // MARK: - Body

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {

                // ── Thumbnail ────────────────────────────────────────────────
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let urlString = summary.thumbnailURL,
                           let url = URL(string: urlString) {
                            CachedAsyncImage(url: url) { img in
                                img.resizable().scaledToFill()
                            } placeholder: { thumbnailPlaceholder }
                        } else {
                            thumbnailPlaceholder
                        }
                    }
                    .frame(width: thumbWidth, height: thumbHeight)
                    .clipped()

                    // Playing indicator pill
                    if isPlaying {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(CinemaTheme.teal)
                                .frame(width: 6, height: 6)
                            Text("Playing")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(8)
                    }
                }
                .frame(width: thumbWidth, height: thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // ── Text block ───────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {

                    // PINEcue provenance badge
                    HStack(spacing: 6) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 11, weight: .medium))
                        Text("Selected in PINEcue")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0.3)
                    }
                    .foregroundStyle(CinemaTheme.peacockLight.opacity(isFocused ? 1.0 : 0.75))

                    // Title
                    Text(summary.title)
                        .font(.system(size: scopeMode ? 18 : 22, weight: .bold))
                        .foregroundStyle(isFocused
                            ? CinemaTheme.primary(settings.colorMode)
                            : .white)
                        .lineLimit(2)

                    // Year
                    if let year = summary.year {
                        Text(String(year))
                            .font(.system(size: scopeMode ? 13 : 15))
                            .foregroundStyle(.white.opacity(0.45))
                    }

                    Spacer(minLength: 0)

                    // Tap hint / loading indicator
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(CinemaTheme.gold)
                                .scaleEffect(0.65)
                        } else {
                            Text("View Details")
                                .font(.system(size: scopeMode ? 12 : 14, weight: .medium))
                            Image(systemName: "arrow.right")
                                .font(.system(size: scopeMode ? 11 : 13))
                        }
                    }
                    .foregroundStyle(isFocused
                        ? CinemaTheme.gold
                        : .white.opacity(0.30))
                    .opacity(isFocused ? 1 : 0.8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: thumbHeight)
            .background {
                ZStack {
                    // Base surface
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            isFocused
                                ? CinemaTheme.peacock.opacity(0.55)
                                : CinemaTheme.peacockDeep.opacity(0.50)
                        )
                    // Top-edge specular sheen
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(isFocused ? 0.12 : 0.05), location: 0),
                            .init(color: .clear, location: 0.50),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            // Gold left accent bar
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(CinemaTheme.gold.opacity(isFocused ? 1.0 : 0.55))
                    .frame(width: 3)
                    .padding(.vertical, 14)
                    .padding(.leading, 1)
            }
            // Focus ring
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isFocused
                            ? LinearGradient(
                                colors: [CinemaTheme.gold.opacity(0.7), CinemaTheme.peacockLight.opacity(0.4)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(
                                colors: [.white.opacity(0.08)],
                                startPoint: .top, endPoint: .bottom),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            }
            .scaleEffect(isFocused ? 1.025 : 1.0, anchor: .leading)
            .shadow(
                color: isFocused ? CinemaTheme.gold.opacity(0.20) : .clear,
                radius: 20, x: 0, y: 8
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.72), value: isFocused)
        }
        .focusRingFree()
        .focused($isFocused)
    }

    // MARK: - Placeholder

    private var thumbnailPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(CinemaTheme.peacockDeep)
            Image(systemName: "film")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(CinemaTheme.peacockLight.opacity(0.35))
        }
        .frame(width: thumbWidth, height: thumbHeight)
    }
}
