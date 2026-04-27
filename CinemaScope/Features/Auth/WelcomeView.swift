import SwiftUI

// MARK: - WelcomeView
//
// Landing screen shown to unauthenticated users.
// If no backend URL has been configured yet, a setup step is shown first.

struct WelcomeView: View {

    @EnvironmentObject var env: PINEAEnvironment

    enum Destination { case login, register, backendSetup }
    @State private var destination: Destination? = nil

    // Focus targets
    enum Focus: Hashable { case signIn, createAccount, backendURL, saveURL }
    @FocusState private var focus: Focus?

    // Backend URL editor (shown inline if not configured)
    @State private var backendDraft:     String = ""
    @State private var showingURLEditor: Bool   = false

    // Entrance animation
    @State private var contentVisible = false

    var body: some View {
        ZStack {
            background

            switch destination {
            case .login:
                LoginView()
                    .environmentObject(env)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))

            case .register:
                RegisterView()
                    .environmentObject(env)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))

            case .backendSetup:
                BackendSetupSheet(draft: $backendDraft) {
                    env.backendBaseURL = backendDraft
                    destination = nil
                } onCancel: {
                    destination = nil
                }
                .environmentObject(env)
                .transition(.opacity)

            case nil:
                mainContent
            }
        }
        .animation(.easeInOut(duration: 0.3), value: destination)
        .onAppear {
            backendDraft = env.backendBaseURL
            withAnimation(.easeOut(duration: 0.8).delay(0.2)) {
                contentVisible = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                focus = .signIn
            }
        }
    }

    // MARK: - Main content

    private var mainContent: some View {
        HStack(spacing: 0) {
            // ── Left: brand panel ─────────────────────────────────────────
            brandPanel
                .frame(maxWidth: .infinity)

            // ── Right: action panel ───────────────────────────────────────
            actionPanel
                .frame(maxWidth: 560)
        }
        .opacity(contentVisible ? 1 : 0)
        .offset(y: contentVisible ? 0 : 32)
    }

    // MARK: - Brand panel

    private var brandPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                // Pinecone
                Image("pinea_pinecone")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 400)
                    .shadow(color: CinemaTheme.gold.opacity(0.35), radius: 40, x: 0, y: 8)
                    .shadow(color: CinemaTheme.accentGold.opacity(0.18), radius: 80, x: 0, y: 0)

                // Wordmark
                Text("PINEA")
                    .font(.system(size: 72, weight: .regular, design: .serif))
                    .foregroundStyle(CinemaTheme.gold)
                    .tracking(12)

                // Tagline
                Text("Your cinema. Elevated.")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .tracking(1)
            }

            Spacer()

            // Backend URL indicator
            backendIndicator
                .padding(.bottom, 48)
        }
        .padding(.horizontal, 80)
    }

    // MARK: - Action panel

    private var actionPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 48) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Welcome back")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Sign in to continue watching,\nor create a new account.")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineSpacing(4)
                }

                VStack(spacing: 18) {
                    // Sign In
                    WelcomeActionButton(
                        label:     "Sign In",
                        icon:      "person.fill",
                        isPrimary: true,
                        isFocused: focus == .signIn
                    ) {
                        withAnimation { destination = .login }
                    }
                    .focused($focus, equals: .signIn)

                    // Create Account
                    WelcomeActionButton(
                        label:     "Create Account",
                        icon:      "person.badge.plus",
                        isPrimary: false,
                        isFocused: focus == .createAccount
                    ) {
                        withAnimation { destination = .register }
                    }
                    .focused($focus, equals: .createAccount)
                }
                .focusSection()
            }

            Spacer()
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 60)
        .background(.ultraThinMaterial.opacity(0.25))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [CinemaTheme.gold.opacity(0.25), CinemaTheme.peacock.opacity(0.15)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 1)
        }
    }

    // MARK: - Backend URL indicator

    private var backendIndicator: some View {
        Button {
            backendDraft = env.backendBaseURL
            withAnimation { destination = .backendSetup }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(env.backendBaseURL.isEmpty ? Color.orange : CinemaTheme.teal)
                    .frame(width: 8, height: 8)
                Text(env.backendBaseURL.isEmpty ? "Backend not configured" : "Connected to PINEA")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.4))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .focusRingFree()
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            CinemaTheme.backgroundGradient(.dark)
            CinemaTheme.radialOverlay(.dark)
        }
        .ignoresSafeArea()
    }
}

// MARK: - WelcomeActionButton

private struct WelcomeActionButton: View {
    let label:     String
    let icon:      String
    let isPrimary: Bool
    let isFocused: Bool
    let action:    () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .light))
                Text(label)
                    .font(.system(size: 22, weight: isPrimary ? .semibold : .regular))
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 16))
                    .opacity(isFocused ? 1 : 0)
            }
            .foregroundStyle(isPrimary
                ? (isFocused ? Color.black  : CinemaTheme.gold)
                : (isFocused ? Color.white  : Color.white.opacity(0.55)))
            .padding(.horizontal, 32)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    if isPrimary {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(isFocused ? CinemaTheme.gold : CinemaTheme.gold.opacity(0.14))
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.white.opacity(isFocused ? 0.14 : 0.06))
                    }
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            isPrimary
                                ? (isFocused ? Color.clear : CinemaTheme.gold.opacity(0.4))
                                : Color.white.opacity(isFocused ? 0.25 : 0.12),
                            lineWidth: 1
                        )
                }
            }
            .scaleEffect(isFocused ? 1.03 : 1.0)
            .shadow(color: isPrimary && isFocused ? CinemaTheme.gold.opacity(0.4) : .clear,
                    radius: 20, x: 0, y: 6)
            .animation(.spring(response: 0.25, dampingFraction: 0.72), value: isFocused)
        }
        .focusRingFree()
    }
}

// MARK: - BackendSetupSheet

private struct BackendSetupSheet: View {
    @Binding var draft: String
    let onSave:   () -> Void
    let onCancel: () -> Void

    @EnvironmentObject var env: PINEAEnvironment
    @FocusState private var focus: BackendFocus?
    enum BackendFocus: Hashable { case field, save, cancel }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 40) {
                VStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(CinemaTheme.gold)
                    Text("PINEA Backend")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Enter the URL of your PINEA platform server.")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                }

                PINEAFormField<BackendFocus>(
                    label:       "Backend URL",
                    placeholder: "https://api.pinea.tv",
                    text:        $draft,
                    isFocused:   focus == .field,
                    icon:        "link"
                )
                .frame(maxWidth: 640)
                .focused($focus, equals: .field)
                .onSubmit { focus = .save }

                HStack(spacing: 24) {
                    Button("Cancel") { onCancel() }
                        .focusRingFree()
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(focus == .cancel ? 1.0 : 0.4))
                        .focused($focus, equals: .cancel)

                    Button("Save") { onSave() }
                        .focusRingFree()
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(focus == .save ? .black : CinemaTheme.gold)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 16)
                        .background(focus == .save ? CinemaTheme.gold : CinemaTheme.gold.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .scaleEffect(focus == .save ? 1.04 : 1.0)
                        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: focus)
                        .focused($focus, equals: .save)
                }
                .focusSection()
            }
            .padding(64)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .frame(maxWidth: 780)
        }
        .onAppear { focus = .field }
    }
}
