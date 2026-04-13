import SwiftUI

struct UserPickerView: View {

    let server:   EmbyServer
    let onSelect: (EmbyUser) -> Void
    let onBack:   () -> Void

    @State private var users:     [EmbyUser] = []
    @State private var isLoading  = true
    @State private var error:     String?    = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 60) {
                header

                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.5)
                } else if let error {
                    errorView(error)
                } else {
                    userGrid
                }
            }
            .padding(80)
        }
        .task { await loadUsers() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Text("Who's watching?")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(.white)
            Text(server.url)
                .font(.system(size: 20, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    // MARK: - User Grid

    private var userGrid: some View {
        HStack(spacing: 40) {
            ForEach(users) { user in
                UserTile(user: user, server: server) {
                    onSelect(user)
                }
            }
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Go Back") { onBack() }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - Load

    private func loadUsers() async {
        isLoading = true
        error     = nil
        do {
            users     = try await EmbyAPI.fetchUsers(server: server)
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading  = false
        }
    }
}

// MARK: - UserTile

struct UserTile: View {

    let user:   EmbyUser
    let server: EmbyServer
    let onTap:  () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 20) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.1))
                        .frame(width: 160, height: 160)

                    if let imageURL = avatarURL {
                        AsyncImage(url: imageURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            initialsView
                        }
                        .frame(width: 160, height: 160)
                        .clipShape(Circle())
                    } else {
                        initialsView
                    }
                }
                .scaleEffect(isFocused ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isFocused)

                Text(user.name)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .focused($isFocused)
    }

    private var initialsView: some View {
        Text(user.name.prefix(1).uppercased())
            .font(.system(size: 56, weight: .bold))
            .foregroundStyle(.white.opacity(0.6))
    }

    private var avatarURL: URL? {
        guard let tag = user.primaryImageTag else { return nil }
        return URL(string: "\(server.url)/Users/\(user.id)/Images/Primary?tag=\(tag)&width=160")
    }
}
