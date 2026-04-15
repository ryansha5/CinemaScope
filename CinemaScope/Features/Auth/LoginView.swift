import SwiftUI

struct LoginView: View {

    let server:   EmbyServer
    let user:     EmbyUser
    let onLogin:  (String) -> Void  // passes back the token
    let onBack:   () -> Void

    @State private var password  = ""
    @State private var isLoading = false
    @State private var error:    String? = nil

    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 48) {
                // Avatar + name
                VStack(spacing: 20) {
                    Circle()
                        .fill(.white.opacity(0.1))
                        .frame(width: 120, height: 120)
                        .overlay {
                            Text(user.name.prefix(1).uppercased())
                                .font(.system(size: 48, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                        }

                    Text(user.name)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.white)
                }

                // Password field
                VStack(alignment: .leading, spacing: 16) {
                    SecureField("Password", text: $password)
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .padding(24)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .focused($fieldFocused)
                        .frame(maxWidth: 500)
                        .onSubmit { login() }

                    if let error {
                        Text(error)
                            .font(.system(size: 18))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }

                // Buttons
                HStack(spacing: 24) {
                    Button("Back") { onBack() }
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.5))
                        .buttonStyle(.plain)

                    Button {
                        login()
                    } label: {
                        Group {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.black)
                            } else {
                                Text("Sign In")
                                    .font(.system(size: 22, weight: .semibold))
                            }
                        }
                        .frame(width: 160, height: 56)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
            }
            .padding(80)
        }
        .onAppear { fieldFocused = true }
    }

    private func login() {
        isLoading = true
        error     = nil
        Task {
            do {
                let auth = try await EmbyAPI.authenticate(
                    server:   server,
                    username: user.name,
                    password: password
                )
                isLoading = false
                onLogin(auth.accessToken)
            } catch {
                isLoading  = false
                self.error = error.localizedDescription
            }
        }
    }
}
