import SwiftUI

// MARK: - RecommendationRow
// Sprint 45 — Flip-card design.
// Large 16:9 cards (~2.5 on screen). Pressing select flips the card on the Y axis
// to reveal a mini detail panel with poster, metadata, overview, cast photos, and
// action buttons. The card flips back when focus leaves it or it scrolls fully off.

struct RecommendationRow: View {
    let title:     String
    let items:     [RecommendationItem]
    let session:   EmbySession
    let scopeMode: Bool
    let colorMode: ColorMode
    let onSelect:  (EmbyItem) -> Void      // → DetailView
    let onPlay:    (EmbyItem) -> Void      // → direct playback

    var body: some View {
        VStack(alignment: .leading, spacing: scopeMode ? 10 : 16) {

            Text(title)
                .font(scopeMode
                      ? .system(size: 18, weight: .semibold)
                      : .system(size: 24, weight: .semibold))
                .foregroundStyle(CinemaTheme.primary(colorMode))
                .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CinemaTheme.cardSpacing) {
                    ForEach(items) { item in
                        RecommendationCard(
                            item:      item,
                            session:   session,
                            scopeMode: scopeMode,
                            colorMode: colorMode,
                            onSelect:  onSelect,
                            onPlay:    onPlay
                        )
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
        }
    }
}

// MARK: - RecommendationCard

private struct RecommendationCard: View {

    let item:      RecommendationItem
    let session:   EmbySession
    let scopeMode: Bool
    let colorMode: ColorMode
    let onSelect:  (EmbyItem) -> Void
    let onPlay:    (EmbyItem) -> Void

    // 16:9 — ~2.5 fit the 1920pt tvOS canvas
    private let cardWidth:  CGFloat = 732
    private let cardHeight: CGFloat = 412

    // Poster dimensions — 50% larger than the original 108×162
    private let posterW: CGFloat = 162
    private let posterH: CGFloat = 243

    // MARK: - Focus / flip state

    @State private var isFlipped = false

    // Single focus-target enum covering both faces.
    // nil = nothing in this card is focused → trigger flip-back.
    enum FocusTarget: Hashable { case front, play, details }
    @FocusState private var focus: FocusTarget?

    // MARK: - Body

    var body: some View {
        ZStack {
            // ── Front face ──────────────────────────────────────────────────
            frontFace
                .opacity(isFlipped ? 0 : 1)

            // ── Back face (counter-rotated so text reads correctly) ──────────
            backFace
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 1 : 0)
        }
        .frame(width: cardWidth, height: cardHeight)
        // ── Flip the whole card ──────────────────────────────────────────────
        .rotation3DEffect(
            .degrees(isFlipped ? -180 : 0),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.4
        )
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: isFlipped)
        // ── Focus → flip-back when nothing in this card is focused ──────────
        .onChange(of: focus) { _, newFocus in
            if newFocus == nil && isFlipped {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    isFlipped = false
                }
            }
        }
        // ── Auto-focus play button once flip animation starts ────────────────
        .onChange(of: isFlipped) { _, flipped in
            if flipped {
                // Give the animation a half-beat so the flip visual leads focus.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    focus = .play
                }
            }
        }
        // ── Scroll-off safety: flip back when card leaves the visible screen ─
        .background(scrollOffDetector)
    }

    // MARK: - Front Face

    private var frontFace: some View {
        Button {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                isFlipped = true
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                backdropImage
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear,                    location: 0.35),
                        .init(color: Color.black.opacity(0.75), location: 0.72),
                        .init(color: Color.black.opacity(0.95), location: 1.0),
                    ]),
                    startPoint: .top,
                    endPoint:   .bottom
                )
                .frame(width: cardWidth, height: cardHeight)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.recommendation.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CinemaTheme.accentGold)
                        Text("Because you watched \(item.becauseOf.name)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(CinemaTheme.accentGold)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(focusRingOverlay(for: .front))
        }
        .focusRingFree()
        .focused($focus, equals: .front)
        .scaleEffect(focus == .front ? 1.05 : 1.0)
        .shadow(
            color: focus == .front
                ? CinemaTheme.focusAccent(colorMode).opacity(0.55)
                : Color.black.opacity(0.3),
            radius: focus == .front ? 18 : 8
        )
        .shadow(
            color: focus == .front ? CinemaTheme.focusGlow(colorMode) : .clear,
            radius: focus == .front ? 8 : 0
        )
        .animation(.easeInOut(duration: 0.15), value: focus == .front)
    }

    // MARK: - Back Face

    private var backFace: some View {
        ZStack {
            // Background: blurred backdrop + dark scrim
            backdropImage
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
                .blur(radius: 16)
                .overlay(Color.black.opacity(0.78))

            HStack(alignment: .top, spacing: 20) {

                // ── Left: Poster ─────────────────────────────────────────────
                posterImage
                    .frame(width: posterW, height: posterH)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.6), radius: 10, x: 0, y: 5)

                // ── Right: Metadata + cast + buttons ─────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    let rec = item.recommendation

                    // Title
                    Text(rec.name)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    // Year · Rating · Runtime
                    metadataLine(rec)
                        .padding(.top, 5)

                    // Stars + genres on same row
                    HStack(spacing: 12) {
                        if let rating = rec.communityRating {
                            starRatingView(rating)
                        }
                        genreChips(rec)
                    }
                    .padding(.top, 7)

                    // Overview — larger, more lines
                    if let overview = rec.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.70))
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }

                    // Cast photos
                    castRow(rec)
                        .padding(.top, 12)

                    Spacer(minLength: 4)

                    // Attribution
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CinemaTheme.accentGold)
                        Text("Because you watched \(item.becauseOf.name)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(CinemaTheme.accentGold)
                            .lineLimit(1)
                    }

                    // Action buttons
                    HStack(spacing: 14) {
                        // Play (primary)
                        Button {
                            onPlay(item.recommendation)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text("Play")
                            }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(.white.opacity(focus == .play ? 1.0 : 0.88))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .scaleEffect(focus == .play ? 1.06 : 1.0)
                            .shadow(color: focus == .play ? .white.opacity(0.45) : .clear, radius: 10)
                            .animation(.easeInOut(duration: 0.12), value: focus == .play)
                        }
                        .focusRingFree()
                        .focused($focus, equals: .play)

                        // More Details (secondary)
                        Button {
                            onSelect(item.recommendation)
                        } label: {
                            Text("More Details")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(focus == .details ? 1.0 : 0.75))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(.white.opacity(focus == .details ? 0.18 : 0.09))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.white.opacity(focus == .details ? 0.5 : 0.2), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .scaleEffect(focus == .details ? 1.06 : 1.0)
                                .animation(.easeInOut(duration: 0.12), value: focus == .details)
                        }
                        .focusRingFree()
                        .focused($focus, equals: .details)
                    }
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Cast Row

    @ViewBuilder
    private func castRow(_ rec: EmbyItem) -> some View {
        let actors = (rec.people ?? [])
            .filter { $0.type == "Actor" }
            .prefix(6)

        if !actors.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("CAST")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.4))

                HStack(spacing: 14) {
                    ForEach(Array(actors), id: \.id) { person in
                        VStack(spacing: 5) {
                            // Circular headshot
                            Group {
                                if let url = personImageURL(person) {
                                    CachedAsyncImage(url: url) { img in
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        personPlaceholder
                                    }
                                } else {
                                    personPlaceholder
                                }
                            }
                            .frame(width: 52, height: 52)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))

                            // Name
                            Text(person.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                                .frame(width: 62)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Scroll-off Detector

    private var scrollOffDetector: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            Color.clear
                .onChange(of: frame.minX) { _, minX in
                    if isFlipped && (frame.maxX < 60 || minX > 1860) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                            isFlipped = false
                        }
                    }
                }
        }
    }

    // MARK: - Focus Ring

    private func focusRingOverlay(for target: FocusTarget) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                focus == target
                    ? CinemaTheme.focusRimGradient(colorMode)
                    : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
                lineWidth: 4
            )
    }

    // MARK: - Metadata subviews

    @ViewBuilder
    private func metadataLine(_ rec: EmbyItem) -> some View {
        HStack(spacing: 0) {
            if let year = rec.productionYear {
                Text("\(year)")
            }
            if let rating = rec.officialRating {
                Text("  ·  \(rating)")
            }
            if let mins = rec.runtimeMinutes {
                Text("  ·  \(mins)m")
            }
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
    }

    @ViewBuilder
    private func starRatingView(_ rating: Double) -> some View {
        let stars = rating / 2.0
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                let filled = Double(i) < stars - 0.25
                let half   = !filled && Double(i) < stars + 0.25
                Image(systemName: filled ? "star.fill" : half ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(CinemaTheme.accentGold)
            }
            Text(String(format: "%.1f", rating))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CinemaTheme.accentGold.opacity(0.9))
                .padding(.leading, 4)
        }
    }

    @ViewBuilder
    private func genreChips(_ rec: EmbyItem) -> some View {
        if let genres = rec.genres, !genres.isEmpty {
            HStack(spacing: 7) {
                ForEach(genres.prefix(2), id: \.self) { genre in
                    Text(genre)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.80))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }

    // MARK: - Image URLs

    private func personImageURL(_ person: EmbyPerson) -> URL? {
        guard let server = session.server,
              let tag    = person.primaryImageTag else { return nil }
        return EmbyAPI.primaryImageURL(server: server, itemId: person.id, tag: tag, width: 104)
    }

    // MARK: - Image views

    @ViewBuilder
    private var backdropImage: some View {
        let w = Int(cardWidth * 2)
        if let url = backdropURL(width: w) {
            CachedAsyncImage(url: url) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholderView
            }
        } else {
            placeholderView
        }
    }

    @ViewBuilder
    private var posterImage: some View {
        // 2× the display size for crisp 4K rendering
        let w = Int(posterW * 2)
        if let url = posterURL(width: w) {
            CachedAsyncImage(url: url) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                posterPlaceholder
            }
        } else {
            posterPlaceholder
        }
    }

    private func backdropURL(width: Int) -> URL? {
        guard let server = session.server else { return nil }
        let rec = item.recommendation
        if let tag = rec.backdropImageTags?.first {
            return EmbyAPI.backdropImageURL(server: server, itemId: rec.id, tag: tag, width: width)
        }
        if let tag = rec.imageTags?.thumb {
            return EmbyAPI.thumbImageURL(server: server, itemId: rec.id, tag: tag, width: width)
        }
        if let tag = rec.imageTags?.primary {
            return EmbyAPI.primaryImageURL(server: server, itemId: rec.id, tag: tag, width: width)
        }
        return nil
    }

    private func posterURL(width: Int) -> URL? {
        guard let server = session.server else { return nil }
        let rec = item.recommendation
        if let tag = rec.imageTags?.primary {
            return EmbyAPI.primaryImageURL(server: server, itemId: rec.id, tag: tag, width: width)
        }
        if let tag = rec.imageTags?.thumb {
            return EmbyAPI.thumbImageURL(server: server, itemId: rec.id, tag: tag, width: width)
        }
        return nil
    }

    private var placeholderView: some View {
        ZStack {
            Color(red: 0.08, green: 0.12, blue: 0.20)
            VStack(spacing: 8) {
                Image(systemName: item.recommendation.type == "Series" ? "tv" : "film")
                    .font(.system(size: 36))
                    .foregroundStyle(CinemaTheme.accentGold.opacity(0.4))
                Text(item.recommendation.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .lineLimit(2)
            }
        }
    }

    private var posterPlaceholder: some View {
        ZStack {
            Color(red: 0.08, green: 0.12, blue: 0.20)
            Image(systemName: "photo")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.2))
        }
    }

    private var personPlaceholder: some View {
        ZStack {
            Circle().fill(.white.opacity(0.08))
            Image(systemName: "person.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.25))
        }
    }
}
