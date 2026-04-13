import SwiftUI

struct CollectionDetailView: View {

    let collection: EmbyItem
    let session:    EmbySession
    let onSelect:   (EmbyItem) -> Void
    let onBack:     () -> Void

    @State private var items:     [EmbyItem] = []
    @State private var isLoading  = true
    @State private var error:     String?    = nil

    @EnvironmentObject var settings: AppSettings

    var columns: [GridItem] {
        let count  = settings.scopeUIEnabled ? 7 : 5
        let spacing: CGFloat = settings.scopeUIEnabled ? 14 : CinemaTheme.cardSpacing
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    var body: some View {
        ZStack {
            CinemaBackground()

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(alignment: .bottom, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(collection.name)
                            .font(CinemaTheme.titleFont)
                            .foregroundStyle(.white)
                        if !items.isEmpty {
                            Text("\(items.count) \(items.first?.type == "Series" ? "shows" : "movies")")
                                .font(CinemaTheme.bodyFont)
                                .foregroundStyle(CinemaTheme.peacockLight.opacity(0.7))
                        }
                    }
                    Spacer()
                    Button {
                        onBack()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(CinemaTheme.peacock.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    .focusRingFree()
                }
                .padding(.horizontal, CinemaTheme.pagePadding)
                .padding(.top, 60)
                .padding(.bottom, 40)
                .focusSection()

                // Content
                if isLoading {
                    Spacer()
                    HStack {
                        Spacer()
                        ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.5)
                        Spacer()
                    }
                    Spacer()
                } else if let error {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48)).foregroundStyle(.yellow)
                        Text(error).foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                } else if items.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 64))
                            .foregroundStyle(.white.opacity(0.2))
                        Text("This collection is empty")
                            .font(CinemaTheme.bodyFont)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: CinemaTheme.cardSpacing) {
                            ForEach(items) { item in
                                GridCard(item: item, session: session, scopeMode: settings.scopeUIEnabled) {
                                    onSelect(item)
                                }
                            }
                        }
                        .padding(.horizontal, CinemaTheme.pagePadding)
                        .padding(.vertical, 20)
                        .padding(.bottom, 60)
                    }
                    .clipped(antialiased: false)
                    .focusSection()
                }
            }
        }
        .task { await loadItems() }
    }

    private func loadItems() async {
        guard let server = session.server,
              let user   = session.user,
              let token  = session.token else { return }
        isLoading = true
        do {
            let response = try await EmbyAPI.fetchItems(
                server:   server,
                userId:   user.id,
                token:    token,
                parentId: collection.id,
                limit:    10000
            )
            items     = response.items
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading  = false
        }
    }
}
