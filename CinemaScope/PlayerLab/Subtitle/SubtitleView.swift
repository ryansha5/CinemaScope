// MARK: - PlayerLab / Subtitle / SubtitleView
//
// Sprint 26 — Subtitle text overlay for PlayerLabPlayerView.
//
// Renders a single SubtitleCue as white text with a drop shadow,
// positioned above the HUD controls.  Non-interactive (allowsHitTesting false).
//
// Styling is intentionally minimal — Sprint 26 scope.
// Bold text + shadow renders well against both dark and light backgrounds
// without a separate background box.

import SwiftUI
import CoreMedia

struct SubtitleView: View {

    let cue: SubtitleCue?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if let cue {
                Text(cue.text)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    // Drop shadow creates legibility on any background colour
                    .shadow(color: .black.opacity(0.9), radius: 3, x: 1, y: 1)
                    .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 0)
                    .padding(.horizontal, 80)
                    // 150 pt clearance keeps subtitles above the ~120 pt HUD bar
                    .padding(.bottom, 150)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
