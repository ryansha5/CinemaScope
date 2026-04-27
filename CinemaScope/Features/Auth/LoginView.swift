import SwiftUI

// MARK: - LoginView  (PINEA platform auth)
//
// Authenticates against /api/auth/login via AuthService.
// On success, calls env.didAuthenticate() which updates routing state.
// Decoupled from backend routes — only AuthService knows about those.

struct LoginView: View {

    @EnvironmentObject var env: PINEAEnvironment

    @State private var goToRegister  = false
    @State private var email         = ""
    @State private var password      = ""
    @State private var isLoading     = false
    @State private var errorMessage: String? = nil
    @State private var visible       = false

    enum Field: Hashable { case email, password, signIn, register }
    @FocusState private var focus: Field?

    var body: some View {
        ZStack {
            background

            if goToRegister {
                RegisterView()
                    .environmentObject(env)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))
            } else {
                splitLayout
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 24)
            }
        }
        .animation(.easeOut(duration: 0.28), value: goToRegister)
        .animation(.easeOut(duration: 0.5), value: visible)
        .onAppear {
            visible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focus = .email }
        }
    }

    // MARK: - Layout

    private var splitLayout: some View {
        HStack(spacing: 0) {
            brandSidebar.frame(maxWidth: 380)
            formPanel.frame(maxWidth: .infinity)
        }
    }

    // MARK: - Brand sidebar

    private var brandSidebar: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                Image("pinea_pinecone")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 140)
                    .shadow(color: CinemaTheme.gold.opacity(0.3), radius: 30, x: 0, y: 6)
                Text("PINEA")
                    .font(.system(size: 48, weight: .regular, design: .serif))
                    .foregroundStyle(CinemaTheme.gold)
                    .tracking(10)
                Text("Your cinema. Elevated.")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
                    .tracking(0.5)
            }
            Spacer()
        }
        .padding(.horizontal, 60)
    }

    // MARK: - Form panel

    private var formPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 40) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome back")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Sign in to your PINEA account")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.45))
                }

                // Fields
                VStack(spacing: 20) {
                    PINEAFormField<Field>(
                        label:       "Email",
                        placeholder: "you@example.com",
                        text:        $email,
                        isFocused:   focus == .email,
                        icon:        "envelope"
                    )
                    .focused($focus, equals: .email)
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
                    .onSubmit { focus = .signIn }
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

                // Buttons
                VStack(spacing: 16) {
                    primaryButton
                    registerLink
                }
                .focusSection()
            }

            Spacer()
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 60)
        .background(.ultraThinMaterial.opacity(0.2))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LinearGradient(
                    colors: [CinemaTheme.gold.opacity(0.25), CinemaTheme.peacock.opacity(0.15)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
        }
    }

    // MARK: - Primary button

    private var primaryButton: some View {
        Button { signIn() } label: {
            ZStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(focus == .signIn ? .black : CinemaTheme.gold)
                } else {
                    HStack(spacing: 10) {
                        Text("Sign In")
                            .font(.system(size: 22, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
            }
            .foregroundStyle(focus == .signIn ? .black : CinemaTheme.gold)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(focus == .signIn ? CinemaTheme.gold : CinemaTheme.gold.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(CinemaTheme.gold.opacity(focus == .signIn ? 0 : 0.4), lineWidth: 1)
                    }
            }
            .scaleEffect(focus == .signIn ? 1.03 : 1.0)
            .shadow(color: focus == .signIn ? CinemaTheme.gold.opacity(0.45) : .clear, radius: 18)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: focus)
        }
        .focusRingFree()
        .focused($focus, equals: .signIn)
        .disabled(isLoading || email.isEmpty || password.isEmpty)
    }

    // MARK: - Register link

    private var registerLink: some View {
        Button { withAnimation { goToRegister = true } } label: {
            HStack(spacing: 6) {
                Text("Don't have an account?")
                    .foregroundStyle(.white.opacity(0.4))
                Text("Create one")
                    .foregroundStyle(focus == .register ? CinemaTheme.gold : CinemaTheme.peacockLight)
                    .underline(focus == .register)
            }
            .font(.system(size: 18))
        }
        .focusRingFree()
        .focused($focus, equals: .register)
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

    private func signIn() {
        // ── Dev bypass (Sprint 1: simulate login without backend) ───────────
        // Uses env.simulateLogin() — same path as a real auth success.
        // Remove or gate behind #if DEBUG before shipping.
        if email.trimmingCharacters(in: .whitespaces) == DevConfig.email,
           password == DevConfig.password {
            env.simulateLogin()
            return
        }
        // ────────────────────────────────────────────────────────────────────

        guard !env.backendBaseURL.isEmpty else {
            errorMessage = "No backend URL configured. Use dev credentials to bypass."
            return
        }
        isLoading    = true
        errorMessage = nil
        Task {
            do {
                let res = try await AuthService.shared.login(
                    baseURL:  env.backendBaseURL,
                    email:    email.trimmingCharacters(in: .whitespaces),
                    password: password
                )
                await MainActor.run {
                    isLoading = false
                    env.didAuthenticate(user: res.user, token: res.token)
                }
            } catch {
                await MainActor.run {
                    isLoading    = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Dev credentials
// Change these to whatever you want. Delete this enum before shipping.
private enum DevConfig {
    static let email    = "dev@pinea.tv"
    static let password = "pinea123"
}
