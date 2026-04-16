import SwiftUI

// MARK: - DetailCastSection
//
// Horizontal cast ribbon — prefers TMDB cast (profile photos + character names),
// falls back to Emby cast (initials avatars).
// Caller decides which to show; pass empty arrays for the unused source.
// Extracted from DetailView (PASS 3). No logic changes.

struct DetailCastSection: View {
    let tmdbCast:   [TMDBCastMember]   // non-empty → shows TMDB ribbon
    let embyActors: [EmbyPerson]       // fallback when tmdbCast is empty
    let session:    EmbySession
    let scopeMode:  Bool
    let colorMode:  ColorMode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cast")
                .font(.system(size: scopeMode ? 18 : 22, weight: .semibold))
                .foregroundStyle(CinemaTheme.primary(colorMode))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: scopeMode ? 16 : 24) {
                    if !tmdbCast.isEmpty {
                        ForEach(tmdbCast) { member in
                            TMDBCastCard(member: member, scopeMode: scopeMode,
                                         colorMode: colorMode)
                        }
                    } else {
                        ForEach(embyActors.prefix(20)) { person in
                            CastCard(person: person, session: session,
                                     scopeMode: scopeMode, colorMode: colorMode)
                        }
                    }
                }
                .padding(.vertical, 24)
                .padding(.trailing, scopeMode ? 28 : 80)
            }
            .scrollClipDisabled()
        }
    }
}
