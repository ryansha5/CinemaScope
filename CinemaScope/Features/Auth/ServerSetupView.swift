import SwiftUI

// MARK: - ServerSetupView
//
// Shown after PINEA auth is established but before a media library
// has been connected.  Collects the user's Emby server details,
// validates directly against Emby, then registers the connection
// with the PINEA backend via ServerService.

struct ServerSetupView: View {

    @EnvironmentObject var env: PINEAEnvironment

    @State private var serverURL  = ""
    @State private var username   = ""
    @State private var password   = ""
    @State private var isLoading  = false
    @State private var errorMessage: String? = nil
    @State private var visible    = false

    enum Field: Hashable { case serverURL, username, password, connect }
    @FocusState private var focus: Field?

    var body: some View {
        ZStack {
            background
            splitLayout
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 24)
        }
        .animation(.easeOut(duration: 0.5), value: visible)
        .onAppear {
            visible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focus = .serverURL }
        }
    }

    // MARK: - Layout

    private var splitLayout: some View {
        HStack(spacing: 0) {
            infoPanelView.frame(maxWidth: 440)
            formPanel.frame(maxWidth: .infinity)
        }
    }

    // MARK: - Info panel

    private var infoPanelView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 32) {
                // Pinecone — small, tasteful
                Image("pinea_pinecone")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 72)
                    .opacity(0.85)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect your\nmedia library")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                        .lineSpacing(4)

                    Text("Link your personal Emby server\nto unlock your collection on PINEA.")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineSpacing(5)
                }

                // Feature list
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(features, id: \.0) { icon, label in
                        HStack(spacing: 14) {
                            Image(systemName: icon)
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(CinemaTheme.gold.opacity(0.8))
                                .frame(width: 26)
                            Text(label)
                                .font(.system(size: 17))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }
            }

            Spacer()

            // Sign out link
            Button { env.signOut() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.portrait.and.arrow.left")
                        .font(.system(size: 15))
                    Text("Sign out")
                        .font(.system(size: 16))
                }
                .foregroundStyle(.white.opacity(0.3))
            }
            .focusRingFree()
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 60)
    }

    private let features: [(String, String)] = [
        ("film.stack",        "Browse movies and TV in your library"),
        ("arrow.triangle.2.circlepath", "Sync watch progress across devices"),
        ("person.2.fill",     "Share recommendations with friends"),
    ]

    // MARK: - Form panel

    private var formPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Emby Server Details")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Your credentials are validated directly\nand never stored in plain text.")
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineSpacing(4)
                }

                VStack(spacing: 18) {
                    PINEAFormField<Field>(
                        label:       "Server URL",
                        placeholder: "http://192.168.1.10:8096",
                        text:        $serverURL,
                        isFocused:   focus == .serverURL,
                        icon:        "server.rack"
                    )
                    .focused($focus, equals: .serverURL)
                    .onSubmit { focus = .username }

                    PINEAFormField<Field>(
                        label:       "Emby Username",
                        placeholder: "username",
                        text:        $username,
                        isFocused:   focus == .username,
                        icon:        "person"
                    )
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }

                    PINEAFormField<Field>(
                        label:       "Password",
                        placeholder: "••••••••",
                        text:        $password,
                        isSecure:    true,
                        isFocused:   focus == .password,
                        icon:        "lock"
                    )
                    .focused($focus, equals: .password)
                    .onSubmit { focus = .connect }
                }

                // Error
                if let errorMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red.opacity(0.8))
                        Text(errorMessage)
                            .font(.system(size: 17))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                connectButton.focusSection()
            }

            Spacer()
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 60)
        .background(.ultraThinMaterial.opacity(0.2))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LinearGradient(
                    colors: [CinemaTheme.peacockLight.opacity(0.25), CinemaTheme.peacock.opacity(0.1)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
        }
    }

    // MARK: - Connect button

    private var connectButton: some View {
        Button { connect() } label: {
            ZStack {
                if isLoading {
                    HStack(spacing: 14) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(focus == .connect ? .black : CinemaTheme.gold)
                        Text("Connecting…")
                            .font(.system(size: 20, weight: .medium))
                    }
                } else {
                    HStack(spacing: 10) {
                        Text("Connect Library")
                            .font(.system(size: 22, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
            }
            .foregroundStyle(focus == .connect ? .black : CinemaTheme.gold)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(focus == .connect ? CinemaTheme.gold : CinemaTheme.gold.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(CinemaTheme.gold.opacity(focus == .connect ? 0 : 0.4), lineWidth: 1)
                    }
            }
            .scaleEffect(focus == .connect ? 1.03 : 1.0)
            .shadow(color: focus == .connect ? CinemaTheme.gold.opacity(0.45) : .clear, radius: 18)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: focus)
        }
        .focusRingFree()
        .focused($focus, equals: .connect)
        .disabled(isLoading || serverURL.isEmpty || username.isEmpty)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            CinemaTheme.backgroundGradient(.dark)
            CinemaTheme.radialOverlay(.dark)
        }
        .ignoresSafeArea()
    }

    // MARK: - Action

    private func connect() {
        isLoading    = true
        errorMessage = nil
        Task {
            do {
                let (server, user, token) = try await ServerService.shared.connectLibrary(
                    pineaBaseURL:  env.backendBaseURL,
                    pineaToken:    env.pineaToken ?? "",
                    embyServerURL: serverURL.trimmingCharacters(in: .whitespaces),
                    embyUsername:  username.trimmingCharacters(in: .whitespaces),
                    embyPassword:  password
                )
                await MainActor.run {
                    isLoading = false
                    env.didConnectLibrary(server: server, user: user, token: token)
                }
            } catch {
                await MainActor.run {
                    isLoading    = false
                    errorMessage = "Could not connect: \(error.localizedDescription)"
                }
            }
        }
    }
}
