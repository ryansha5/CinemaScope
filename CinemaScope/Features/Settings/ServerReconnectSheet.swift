import SwiftUI

// MARK: - ServerReconnectSheet
//
// Presented from Settings → Server when the user wants to switch to a
// different Emby server address or a different Emby user account.
// Validates credentials directly against Emby via ServerService and,
// on success, fires onConnect so PINEAEnvironment can update its state.

struct ServerReconnectSheet: View {

    let session:   EmbySession
    let colorMode: ColorMode
    let onConnect: (EmbyServer, EmbyUser, String) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject var env: PINEAEnvironment

    @State private var serverURL  = ""
    @State private var username   = ""
    @State private var password   = ""
    @State private var isLoading  = false
    @State private var errorMessage: String? = nil

    enum Field: Hashable { case serverURL, username, password, connect }
    @FocusState private var focus: Field?

    var body: some View {
        ZStack {
            CinemaTheme.backgroundGradient(.dark)
                .ignoresSafeArea()
            CinemaTheme.radialOverlay(.dark)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Change Server / User")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Connect to a different Emby server or switch accounts.")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .focusRingFree()
                }
                .padding(.bottom, 36)

                // Pre-fill current values
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

                if let msg = errorMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red.opacity(0.8))
                        Text(msg)
                            .font(.system(size: 17))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .padding(.top, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Connect button
                connectButton
                    .padding(.top, 28)
                    .focusSection()
            }
            .frame(maxWidth: 720)
            .padding(64)
        }
        .onAppear {
            // Pre-fill with current credentials
            serverURL = session.server?.url ?? ""
            username  = session.user?.name   ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focus = .serverURL }
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
                        Text("Connect")
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
                    onConnect(server, user, token)
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
