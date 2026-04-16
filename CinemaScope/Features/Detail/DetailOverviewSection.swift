import SwiftUI

// MARK: - DetailOverviewSection
//
// Overview text + director/writer crew line + studio line.
// Extracted from DetailView (PASS 3). No logic changes.

struct DetailOverviewSection: View {
    let displayItem: EmbyItem
    let tmdb:        TMDBMetadata?
    let directors:   [EmbyPerson]
    let writers:     [EmbyPerson]
    let scopeMode:   Bool
    let colorMode:   ColorMode

    var body: some View {
        VStack(alignment: .leading, spacing: scopeMode ? 10 : 14) {
            // ── Overview ──
            if let overview = displayItem.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: scopeMode ? 15 : 19))
                    .foregroundStyle(CinemaTheme.secondary(colorMode))
                    .lineLimit(scopeMode ? 4 : 6)
                    .frame(maxWidth: scopeMode ? 560 : 860, alignment: .leading)
            }

            // ── Crew line — prefer TMDB ──
            crewSection

            // ── Studios ──
            if let studios = displayItem.studios, !studios.isEmpty {
                studioLine(studios)
            }
        }
    }

    // MARK: - Crew (TMDB preferred)

    @ViewBuilder
    private var crewSection: some View {
        let tmdbDirs = tmdb?.directors ?? []
        let tmdbWrts = tmdb?.writers   ?? []
        if !tmdbDirs.isEmpty || !tmdbWrts.isEmpty {
            tmdbCrewLine(directors: tmdbDirs, writers: tmdbWrts)
        } else if !directors.isEmpty || !writers.isEmpty {
            embyCrewLine
        }
    }

    private func tmdbCrewLine(directors: [TMDBCrewMember], writers: [TMDBCrewMember]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !directors.isEmpty {
                crewEntry(label: "Director", names: directors.prefix(2).map(\.name))
            }
            if !writers.isEmpty {
                crewEntry(label: "Writer", names: writers.prefix(2).map(\.name))
            }
        }
    }

    private var embyCrewLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !directors.isEmpty {
                crewEntry(label: "Director", names: directors.prefix(2).map(\.name))
            }
            if !writers.isEmpty {
                crewEntry(label: "Writer", names: writers.prefix(2).map(\.name))
            }
        }
    }

    private func crewEntry(label: String, names: [String]) -> some View {
        HStack(spacing: 8) {
            Text(label + ":")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CinemaTheme.tertiary(colorMode))
            Text(names.joined(separator: ", "))
                .font(.system(size: 15))
                .foregroundStyle(CinemaTheme.secondary(colorMode))
        }
    }

    // MARK: - Studios

    private func studioLine(_ studios: [EmbyStudio]) -> some View {
        HStack(spacing: 8) {
            Text("Studio:")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CinemaTheme.tertiary(colorMode))
            Text(studios.prefix(2).map(\.name).joined(separator: ", "))
                .font(.system(size: 15))
                .foregroundStyle(CinemaTheme.secondary(colorMode))
        }
    }
}
