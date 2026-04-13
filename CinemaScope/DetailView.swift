import SwiftUI

struct DetailView: View {

    let item:    EmbyItem
    let session: EmbySession
    let onPlay:  (EmbyItem) -> Void
    let onBack:  () -> Void

    @EnvironmentObject var settings: AppSettings
    @State private var detail: EmbyItem? = nil

    private var displayItem: EmbyItem { detail ?? item }

    var body: some View {
        if settings.scopeUIEnabled {
            scopeLayout
        } else {
            standardLayout
        }
    }

    // MARK: - Standard Layout (full screen)

    private var standardLayout: some View {
        ZStack {
            backdropLayer(full: true)
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                bottomPanel(scopeMode: false)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .task { await loadDetail() }
    }

    // MARK: - Scope Layout (constrained to 2.39:1 canvas)

    private var scopeLayout: some View {
        GeometryReader { geo in
            let screen = geo.size
            let canvas = scopeRect(in: screen)

            ZStack(alignment: .topLeading) {
                // True black outside canvas
                Color.black.ignoresSafeArea()

                // Backdrop + content constrained to canvas
                ZStack(alignment: .bottomLeading) {
                    backdropLayer(full: false)
                        .frame(width: canvas.width, height: canvas.height)
                    bottomPanel(scopeMode: true)
                }
                .frame(width: canvas.width, height: canvas.height)
                .offset(x: canvas.minX, y: canvas.minY)
            }
        }
        .ignoresSafeArea()
        .task { await loadDetail() }
    }

    // MARK: - Backdrop

    private func backdropLayer(full: Bool) -> some View {
        ZStack {
            CinemaTheme.peacockDeep

            if let server = session.server,
               let tag = displayItem.backdropImageTags?.first,
               let url = backdropURL(server: server, tag: tag) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    CinemaTheme.peacockDeep
                }
                .overlay {
                    LinearGradient(
                        colors: [.clear, .clear,
                                 CinemaTheme.peacockDeep.opacity(0.85),
                                 CinemaTheme.peacockDeep],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
        .ignoresSafeArea(edges: full ? .all : [])
    }

    // MARK: - Bottom Panel

    private func bottomPanel(scopeMode: Bool) -> some View {
        HStack(alignment: .bottom, spacing: scopeMode ? 32 : 60) {
            // Poster
            if let server = session.server,
               let tag = displayItem.imageTags?.primary {
                AsyncImage(url: EmbyAPI.primaryImageURL(
                    server: server, itemId: displayItem.id, tag: tag, width: 300)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(CinemaTheme.cardGradient)
                }
                .frame(
                    width:  scopeMode ? 130 : 200,
                    height: scopeMode ? 195 : 300
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 20)
            }

            // Metadata
            VStack(alignment: .leading, spacing: scopeMode ? 12 : 20) {
                Text(displayItem.name)
                    .font(.system(size: scopeMode ? 32 : 48, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    if let year = displayItem.productionYear { metaBadge("\(year)") }
                    if let mins = displayItem.runtimeMinutes { metaBadge(formatRuntime(mins)) }
                    metaBadge(displayItem.type == "Series" ? "TV Series" : "Movie")
                }

                if let overview = displayItem.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: scopeMode ? 16 : 20))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(scopeMode ? 2 : 3)
                        .frame(maxWidth: scopeMode ? 500 : 700, alignment: .leading)
                }

                HStack(spacing: 20) {
                    Button {
                        onPlay(displayItem)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "play.fill")
                                .font(.system(size: scopeMode ? 16 : 20, weight: .semibold))
                            Text(playButtonLabel)
                                .font(.system(size: scopeMode ? 18 : 22, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, scopeMode ? 24 : 36)
                        .padding(.vertical, scopeMode ? 14 : 18)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .focusRingFree()

                    Button {
                        onBack()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .font(.system(size: scopeMode ? 16 : 20))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, scopeMode ? 20 : 28)
                        .padding(.vertical, scopeMode ? 14 : 18)
                        .background(CinemaTheme.peacock.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .focusRingFree()
                }
            }

            Spacer()
        }
        .padding(.horizontal, scopeMode ? 32 : 80)
        .padding(.bottom,     scopeMode ? 32 : 80)
    }

    // MARK: - Helpers

    private var playButtonLabel: String {
        guard let ticks = displayItem.userData?.playbackPositionTicks,
              ticks > 0 else { return "Play" }
        return "Resume"
    }

    private func metaBadge(_ text: String) -> some View {
        Text(text)
            .font(CinemaTheme.captionFont)
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(CinemaTheme.peacock.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 6))
    }

    private func formatRuntime(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func backdropURL(server: EmbyServer, tag: String) -> URL? {
        URL(string: "\(server.url)/Items/\(displayItem.id)/Images/Backdrop?tag=\(tag)&width=1920")
    }

    private func scopeRect(in size: CGSize) -> CGRect {
        let h = size.width / CinemaTheme.scopeRatio
        let y = (size.height - h) / 2
        return CGRect(x: 0, y: y, width: size.width, height: h)
    }

    private func loadDetail() async {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }
        detail = try? await EmbyAPI.fetchItemDetail(
            server: server, userId: user.id, token: token, itemId: item.id
        )
    }
}
