import SwiftUI

// MARK: - RegisterView

struct RegisterView: View {

    @EnvironmentObject var env: PINEAEnvironment

    @State private var username         = ""
    @State private var email            = ""
    @State private var password         = ""
    @State private var confirmPassword  = ""
    @State private var isLoading        = false
    @State private var errorMessage: String? = nil
    @State private var visible          = false
    @State private var goToLogin        = false

    enum Field: Hashable { case username, email, password, confirm, create, login }
    @FocusState private var focus: Field?

    var body: some View {
        ZStack {
            background

            if goToLogin {
                LoginView()
                    .environmentObject(env)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal:   .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else {
                splitLayout
                    .opacity(visible ? 1 : 0)
                    .offset(y: visible ? 0 : 24)
            }
        }
        .animation(.easeOut(duration: 0.28), value: goToLogin)
        .animation(.easeOut(duration: 0.5), value: visible)
        .onAppear {
            visible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focus = .username }
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create your account")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Join PINEA — it only takes a moment.")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.45))
                }

                // Fields
                VStack(spacing: 18) {
                    PINEAFormField<Field>(
                        label:       "Username",
                        placeholder: "yourname",
                        text:        $username,
                        isFocused:   focus == .username,
                        icon:        "person"
                    )
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .email }

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
                        placeholder: "At least 8 characters",
                        text:        $password,
                        isSecure:    true,
                        isFocused:   focus == .password,
                        icon:        "lock"
                    )
                    .focused($focus, equals: .password)
                    .onSubmit { focus = .confirm }

                    PINEAFormField<Field>(
                        label:       "Confirm Password",
                        placeholder: "Repeat your password",
                        text:        $confirmPassword,
                        isSecure:    true,
                        isFocused:   focus == .confirm,
                        icon:        "lock.fill"
                    )
                    .focused($focus, equals: .confirm)
                    .onSubmit { focus = .create }

                    // Password mismatch hint
                    if !confirmPassword.isEmpty && password != confirmPassword {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red.opacity(0.75))
                            Text("Passwords don't match")
                                .font(.system(size: 16))
                                .foregroundStyle(.red.opacity(0.75))
                        }
                        .transition(.opacity)
                    }
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
                    createButton
                    loginLink
                }
                .focusSection()
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 60)
        }
        .background(.ultraThinMaterial.opacity(0.2))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LinearGradient(
                    colors: [CinemaTheme.gold.opacity(0.25), CinemaTheme.peacock.opacity(0.15)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
        }
    }

    // MARK: - Create button

    private var createButton: some View {
        Button { register() } label: {
            ZStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(focus == .create ? .black : CinemaTheme.gold)
                } else {
                    HStack(spacing: 10) {
                        Text("Create Account")
                            .font(.system(size: 22, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
            }
            .foregroundStyle(focus == .create ? .black : CinemaTheme.gold)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(focus == .create ? CinemaTheme.gold : CinemaTheme.gold.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(CinemaTheme.gold.opacity(focus == .create ? 0 : 0.4), lineWidth: 1)
                    }
            }
            .scaleEffect(focus == .create ? 1.03 : 1.0)
            .shadow(color: focus == .create ? CinemaTheme.gold.opacity(0.45) : .clear, radius: 18)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: focus)
        }
        .focusRingFree()
        .focused($focus, equals: .create)
        .disabled(isLoading || !formIsValid)
    }

    // MARK: - Login link

    private var loginLink: some View {
        Button { withAnimation { goToLogin = true } } label: {
            HStack(spacing: 6) {
                Text("Already have an account?")
                    .foregroundStyle(.white.opacity(0.4))
                Text("Sign in")
                    .foregroundStyle(focus == .login ? CinemaTheme.gold : CinemaTheme.peacockLight)
                    .underline(focus == .login)
            }
            .font(.system(size: 18))
        }
        .focusRingFree()
        .focused($focus, equals: .login)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            CinemaTheme.backgroundGradient(.dark)
            CinemaTheme.radialOverlay(.dark)
        }
        .ignoresSafeArea()
    }

    // MARK: - Validation

    private var formIsValid: Bool {
        !username.isEmpty &&
        !email.isEmpty &&
        password.count >= 8 &&
        password == confirmPassword
    }

    // MARK: - Action

    private func register() {
        guard !env.backendBaseURL.isEmpty else {
            errorMessage = "No backend URL configured."
            return
        }
        guard formIsValid else { return }
        isLoading    = true
        errorMessage = nil
        Task {
            do {
                let res = try await AuthService.shared.register(
                    baseURL:  env.backendBaseURL,
                    username: username.trimmingCharacters(in: .whitespaces),
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
