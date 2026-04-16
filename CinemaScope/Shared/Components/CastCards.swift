import SwiftUI

// MARK: - CastCard
//
// Emby cast member avatar + name + role pill.
// Extracted from DetailView — no logic changes.

struct CastCard: View {
    let person:    EmbyPerson
    let session:   EmbySession
    let scopeMode: Bool
    let colorMode: ColorMode
    @FocusState private var isFocused: Bool

    private var size: CGFloat { scopeMode ? 64 : 88 }

    private var avatarURL: URL? {
        guard let server = session.server,
              let tag    = person.primaryImageTag else { return nil }
        return URL(string: "\(server.url)/Items/\(person.id)/Images/Primary?tag=\(tag)&width=\(Int(size * 2))")
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(CinemaTheme.cardGradient(colorMode))
                    .frame(width: size, height: size)
                if let url = avatarURL {
                    CachedAsyncImage(url: url) { img in img.resizable().scaledToFill() }
                        placeholder: { initialsView }
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                } else {
                    initialsView
                }
            }
            .overlay {
                Circle().strokeBorder(
                    isFocused ? CinemaTheme.focusRimGradient(colorMode) :
                    LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                    lineWidth: 2
                )
            }
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: isFocused ? CinemaTheme.focusAccent(colorMode).opacity(0.5) : .clear, radius: 14)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)

            Text(person.name)
                .font(.system(size: scopeMode ? 11 : 13, weight: .medium))
                .foregroundStyle(CinemaTheme.primary(colorMode))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(width: size + 8)

            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(.system(size: scopeMode ? 10 : 11))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    .lineLimit(1)
                    .frame(width: size + 8)
            }
        }
        .focusEffectDisabled()
    }

    private var initialsView: some View {
        Text(person.name.prefix(1).uppercased())
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(CinemaTheme.tertiary(colorMode))
    }
}

// MARK: - TMDBCastCard
//
// TMDB cast member with profile photo + character name.
// Extracted from DetailView — no logic changes.

struct TMDBCastCard: View {
    let member:    TMDBCastMember
    let scopeMode: Bool
    let colorMode: ColorMode
    @FocusState private var isFocused: Bool

    private var size: CGFloat { scopeMode ? 64 : 88 }
    private var profileURL: URL? { TMDBMetadata.profileURL(path: member.profilePath) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(CinemaTheme.cardGradient(colorMode))
                    .frame(width: size, height: size)

                if let url = profileURL {
                    CachedAsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: { initialsView }
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                } else {
                    initialsView
                }
            }
            .overlay {
                Circle().strokeBorder(
                    isFocused
                        ? CinemaTheme.focusRimGradient(colorMode)
                        : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                    lineWidth: 2
                )
            }
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: isFocused ? CinemaTheme.focusAccent(colorMode).opacity(0.5) : .clear, radius: 14)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)

            Text(member.name)
                .font(.system(size: scopeMode ? 11 : 13, weight: .medium))
                .foregroundStyle(CinemaTheme.primary(colorMode))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(width: size + 8)

            if let character = member.character, !character.isEmpty {
                Text(character)
                    .font(.system(size: scopeMode ? 10 : 11))
                    .foregroundStyle(CinemaTheme.tertiary(colorMode))
                    .lineLimit(1)
                    .frame(width: size + 8)
            }
        }
        .focusEffectDisabled()
    }

    private var initialsView: some View {
        Text(member.name.prefix(1).uppercased())
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(CinemaTheme.tertiary(colorMode))
    }
}
